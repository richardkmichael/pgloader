;;;
;;; Tools to handle the SQLite Database
;;;

(in-package :pgloader.sqlite)

;;;
;;; Integration with the pgloader Source API
;;;
(defclass sqlite-connection (fd-connection) ())

(defmethod initialize-instance :after ((slconn sqlite-connection) &key)
  "Assign the type slot to sqlite."
  (setf (slot-value slconn 'type) "sqlite"))

(defmethod open-connection ((slconn sqlite-connection) &key)
  (setf (conn-handle slconn)
        (sqlite:connect (fd-path slconn)))
  (log-message :debug "CONNECTED TO ~a" (fd-path slconn))
  slconn)

(defmethod close-connection ((slconn sqlite-connection))
  (sqlite:disconnect (conn-handle slconn))
  (setf (conn-handle slconn) nil)
  slconn)

(defmethod clone-connection ((slconn sqlite-connection))
  (change-class (call-next-method slconn) 'sqlite-connection))

(defmethod query ((slconn sqlite-connection) sql &key)
  (sqlite:execute-to-list (conn-handle slconn) sql))

(defclass copy-sqlite (copy)
  ((db :accessor db :initarg :db))
  (:documentation "pgloader SQLite Data Source"))

(defmethod initialize-instance :after ((source copy-sqlite) &key)
  "Add a default value for transforms in case it's not been provided."
  (let* ((transforms (when (slot-boundp source 'transforms)
		       (slot-value source 'transforms))))
    (when (and (slot-boundp source 'fields) (slot-value source 'fields))
      (loop for field in (slot-value source 'fields)
         for (column fn) = (multiple-value-bind (column fn)
                               (cast-sqlite-column-definition-to-pgsql field)
                             (list column fn))
         collect column into columns
         collect fn into fns
         finally (progn (setf (slot-value source 'columns) columns)
                        (unless transforms
                          (setf (slot-value source 'transforms) fns)))))))

;;; Map a function to each row extracted from SQLite
;;;
(defun sqlite-encoding (db)
  "Return a BABEL suitable encoding for the SQLite db handle."
  (let ((encoding-string (sqlite:execute-single db "pragma encoding;")))
    (cond ((string-equal encoding-string "UTF-8")    :utf-8)
          ((string-equal encoding-string "UTF-16")   :utf-16)
          ((string-equal encoding-string "UTF-16le") :utf-16le)
          ((string-equal encoding-string "UTF-16be") :utf-16be))))

(declaim (inline parse-value))

(defun parse-value (value sqlite-type pgsql-type &key (encoding :utf-8))
  "Parse value given by SQLite to match what PostgreSQL is expecting.
   In some cases SQLite will give text output for a blob column (it's
   base64) and at times will output binary data for text (utf-8 byte
   vector)."
  (cond ((and (string-equal "text" pgsql-type)
              (eq :blob sqlite-type)
              (not (stringp value)))
         ;; we expected a properly encoded string and received bytes instead
         (babel:octets-to-string value :encoding encoding))

        ((and (string-equal "bytea" pgsql-type)
              (stringp value))
         ;; we expected bytes and got a string instead, must be base64 encoded
         (base64:base64-string-to-usb8-array value))

        ;; default case, just use what's been given to us
        (t value)))

(defmethod map-rows ((sqlite copy-sqlite) &key process-row-fn)
  "Extract SQLite data and call PROCESS-ROW-FN function with a single
   argument (a list of column values) for each row"
  (let ((sql      (format nil "SELECT * FROM ~a" (source sqlite)))
        (pgtypes  (map 'vector #'cast-sqlite-column-definition-to-pgsql
                       (fields sqlite))))
    (with-connection (*sqlite-db* (source-db sqlite))
      (let* ((db (conn-handle *sqlite-db*))
             (encoding (sqlite-encoding db)))
        (handler-case
            (loop
               with statement = (sqlite:prepare-statement db sql)
               with len = (loop :for name
                             :in (sqlite:statement-column-names statement)
                             :count name)
               while (sqlite:step-statement statement)
               for row = (let ((v (make-array len)))
                           (loop :for x :below len
                              :for raw := (sqlite:statement-column-value statement x)
                              :for ptype := (aref pgtypes x)
                              :for stype := (sqlite-ffi:sqlite3-column-type
                                             (sqlite::handle statement)
                                             x)
                              :for val := (parse-value raw stype ptype
                                                       :encoding encoding)
                              :do (setf (aref v x) val))
                           v)
               counting t into rows
               do (funcall process-row-fn row)
               finally
                 (sqlite:finalize-statement statement)
                 (return rows))
          (condition (e)
            (log-message :error "~a" e)
            (update-stats :data (target sqlite) :errs 1)))))))

(defun fetch-sqlite-metadata (sqlite &key including excluding)
  "SQLite introspection to prepare the migration."
  (let (all-columns all-indexes)
    (with-stats-collection ("fetch meta data"
                            :use-result-as-rows t
                            :use-result-as-read t
                            :section :pre)
      (with-connection (conn (source-db sqlite))
        (let ((*sqlite-db* (conn-handle conn)))
          (setf all-columns   (list-all-columns :db *sqlite-db*
                                                :including including
                                                :excluding excluding)

                all-indexes   (list-all-indexes :db *sqlite-db*
                                                :including including
                                                :excluding excluding)))

        ;; return how many objects we're going to deal with in total
        ;; for stats collection
        (+ (length all-columns) (length all-indexes))))

    ;; now return a plist to the caller
    (list :all-columns all-columns
          :all-indexes all-indexes)))

(defmethod copy-database ((sqlite copy-sqlite)
			  &key
			    data-only
			    schema-only
			    (truncate         nil)
			    (disable-triggers nil)
			    (create-tables    t)
			    (include-drop     t)
			    (create-indexes   t)
			    (reset-sequences  t)
                            only-tables
			    including
			    excluding
                            (encoding :utf-8))
  "Stream the given SQLite database down to PostgreSQL."
  (declare (ignore only-tables))
  (let* ((cffi:*default-foreign-encoding* encoding)
         (copy-kernel  (make-kernel 4))
         (copy-channel (let ((lp:*kernel* copy-kernel)) (lp:make-channel)))
         (table-count  0)
         idx-kernel idx-channel)

    (destructuring-bind (&key all-columns all-indexes pkeys)
        (fetch-sqlite-metadata sqlite :including including :excluding excluding)

      (let ((max-indexes
             (loop for (table . indexes) in all-indexes
                maximizing (length indexes))))

        (setf idx-kernel  (when (and max-indexes (< 0 max-indexes))
                            (make-kernel max-indexes)))

        (setf idx-channel (when idx-kernel
                            (let ((lp:*kernel* idx-kernel))
                              (lp:make-channel)))))

      ;; if asked, first drop/create the tables on the PostgreSQL side
      (handler-case
          (cond ((and (or create-tables schema-only) (not data-only))
                 (log-message :notice "~:[~;DROP then ~]CREATE TABLES" include-drop)
                 (with-stats-collection ("create, truncate" :section :pre)
                   (with-pgsql-transaction (:pgconn (target-db sqlite))
                     (create-tables all-columns :include-drop include-drop))))

                (truncate
                 (truncate-tables (target-db sqlite) (mapcar #'car all-columns))))

        (cl-postgres:database-error (e)
          (declare (ignore e))          ; a log has already been printed
          (log-message :fatal "Failed to create the schema, see above.")
          (return-from copy-database)))

      (loop
         for (table-name . columns) in all-columns
         do
           (let ((table-source
                  (make-instance 'copy-sqlite
                                 :source-db  (clone-connection (source-db sqlite))
                                 :target-db  (clone-connection (target-db sqlite))
                                 :source     table-name
                                 :target     (apply-identifier-case table-name)
                                 :fields     columns)))
             ;; first COPY the data from SQLite to PostgreSQL, using copy-kernel
             (unless schema-only
               (incf table-count)
               (copy-from table-source
                          :kernel copy-kernel
                          :channel copy-channel
                          :disable-triggers disable-triggers))

             ;; Create the indexes for that table in parallel with the next
             ;; COPY, and all at once in concurrent threads to benefit from
             ;; PostgreSQL synchronous scan ability
             ;;
             ;; We just push new index build as they come along, if one
             ;; index build requires much more time than the others our
             ;; index build might get unsync: indexes for different tables
             ;; will get built in parallel --- not a big problem.
             (when (and create-indexes (not data-only))
               (let* ((indexes
                       (cdr (assoc table-name all-indexes :test #'string=))))
                 (alexandria:appendf
                  pkeys
                  (create-indexes-in-kernel (target-db sqlite) indexes
                                            idx-kernel idx-channel))))))

      ;; now end the kernels
      (let ((lp:*kernel* copy-kernel))
        (with-stats-collection ("COPY Threads Completion" :section :post
                                                          :use-result-as-read t
                                                          :use-result-as-rows t)
            (let ((workers-count (* 4 table-count)))
              (loop :for tasks :below workers-count
                 :do (destructuring-bind (task table-name seconds)
                         (lp:receive-result copy-channel)
                       (log-message :debug "Finished processing ~a for ~s ~50T~6$s"
                                    task table-name seconds)
                       (when (eq :writer task)
                         (update-stats :data table-name :secs seconds))))
              (prog1
                  workers-count
                (lp:end-kernel)))))

      (let ((lp:*kernel* idx-kernel))
        ;; wait until the indexes are done being built...
        ;; don't forget accounting for that waiting time.
        (when (and create-indexes (not data-only))
          (with-stats-collection ("Index Build Completion" :section :post
                                                           :use-result-as-read t
                                                           :use-result-as-rows t)
              (let ((nb-indexes
                     (reduce #'+ all-indexes :key (lambda (entry)
                                                    (length (cdr entry))))))
                (loop :for count :below nb-indexes
                   :do (lp:receive-result idx-channel))
                nb-indexes)))
        (lp:end-kernel))

      ;; don't forget to reset sequences, but only when we did actually import
      ;; the data.
      (when reset-sequences
        (reset-sequences (mapcar #'car all-columns)
                         :pgconn (target-db sqlite))))))

