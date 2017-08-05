;;; Commentary:

;;;; Principles

;;;;; Work on elements

;; We want to work on elements as returned by =org-element-parse-buffer=.  We only convert to strings at the very end, when we send the list of those to =org-agenda-finalize-entries=.

;;;;; Preserve the call to =org-agenda-finalize-entries=

;; We want to preserve the final call to =org-agenda-finalize-entries= to preserve compatibility with other packages and functions.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'dash)
(require 'cl-lib)

;;;; Commands

(cl-defun org-agenda-ng--agenda (&key match-fns filter-fns)
  (let* ((tree (cddr (org-element-parse-buffer 'headline)))
         (entries (--> (org-agenda-ng--filter-tree tree :match-fns match-fns :filter-fns filter-fns)
                       (mapcar #'org-agenda-ng--format-element it)))
         (result-string (org-agenda-finalize-entries entries 'agenda))
         (target-buffer (get-buffer-create "test-agenda-ng")))
    (with-current-buffer target-buffer
      (read-only-mode -1)
      (erase-buffer)
      (insert result-string)
      (read-only-mode 1)
      (pop-to-buffer (current-buffer)))))

(defmacro org-agenda-ng--test (&rest args)
  `(with-current-buffer (find-buffer-visiting "~/org/main.org")
     (org-agenda-ng--agenda
      ,@args)))

(defun org-agenda-ng--test-agenda ()
  (interactive)
  (org-agenda-ng--test
   :match-fns '((org-agenda-ng--todo-p "TODO")
                (org-agenda-ng--date-p :deadline < "2017-08-05"))))

(defun org-agenda-ng--test-agenda-today ()
  (interactive)
  (org-agenda-ng--test
   :match-fns `((org-agenda-ng--date-p :deadline <= ,(org-today))
                (org-agenda-ng--date-p :scheduled <= ,(org-today)))
   :filter-fns `((org-agenda-ng--todo-p ,org-done-keywords))))

(defun org-agenda-ng--test-todo-list ()
  (interactive)
  (org-agenda-ng--test
   :match-fns '(org-agenda-ng--todo-p)
   :filter-fns `((org-agenda-ng--todo-p ,org-done-keywords))))

;;;; Functions

(cl-defun org-agenda-ng--filter-tree (tree &key match-fns filter-fns)
  (let* ((types '(headline))
         (info nil)
         (first-match nil)
         (fun (lambda (element)
                (when (and (--any? (cl-typecase it
                                     (function (funcall it element))
                                     (cons (apply (car it) element (cdr it))))
                                   match-fns)
                           (or (null filter-fns)
                               (--none? (cl-typecase it
                                          (function (funcall it element))
                                          (cons (apply (car it) element (cdr it))))
                                        filter-fns)))
                  element))))
    (org-element-map tree types fun info first-match)))


;;;; Faces/properties

(defun org-agenda-ng--format-element (element)
  ;; This essentially needs to do what `org-agenda-format-item' does,
  ;; which is a lot.
  "Return ELEMENT as a string with its text-properties set according to its property list.
Its property list should be the second item in the list, as returned by `org-element-parse-buffer'."
  (let* ((properties (second element))
         ;; Remove the :parent property, which so bloats the size of
         ;; the properties list that it makes it essentially
         ;; impossible to debug, because Emacs takes approximately
         ;; forever to show it in the minibuffer or with
         ;; `describe-text-properties'.  Also, remove ":" from key
         ;; symbols.
         (properties (cl-loop for (key val) on properties by #'cddr
                              for key = (intern (cl-subseq (symbol-name key) 1))
                              unless (member key '(parent))
                              append (list key val)))
         (title (--> (org-agenda-ng--add-faces element)
                     (org-element-property :title it)
                     (org-link-display-format it)))
         (todo-keyword (-some--> (org-element-property :todo-keyword element)
                                 (org-agenda-ng--add-todo-face it)))
         (tags (-some--> (org-element-property :tags element)
                         (s-join ":" it)
                         (s-wrap it ":")
                         (org-add-props it nil 'face 'org-tag)))
         (level (org-element-property :level element))
         (category (org-element-property :category element))
         (string (s-join " " (list todo-keyword title tags))))
    (remove-list-of-text-properties 0 (length string) '(line-prefix) string)
    ;; Add all the necessary properties and faces to the whole string
    (--> string
         (org-add-props it properties))))

(defun org-agenda-ng--add-faces (element)
  (org-agenda-ng--add-scheduled-faces element))

(defun org-agenda-ng--add-scheduled-faces (element)
  "Add faces to ELEMENT's title for its scheduled status."
  (if-let ((scheduled-date (org-element-property :scheduled element)))
      (let* ((today-day-number (org-today))
             (scheduled-day-number (org-time-string-to-absolute
                                    (org-element-timestamp-interpreter scheduled-date 'ignore)))
             (todo-keyword (org-element-property :todo-keyword element))
             (done-p (member todo-keyword org-done-keywords))
             (today-p (= today-day-number scheduled-day-number))
             (face (cond
                    (done-p 'org-agenda-done)
                    (today-p 'org-scheduled-today)
                    (t 'org-scheduled)))
             (title (--> (org-element-property :title element)
                         (org-add-props it nil
                           'face face)))
             (properties (--> (second element)
                              (plist-put it :title title))))
        (list (car element)
              properties))
    ;; Not scheduled
    element))

(defun org-agenda-ng--add-todo-face (keyword)
  (when-let ((face (org-get-todo-face keyword)))
    (org-add-props keyword nil 'face face)))

;;;; Predicates

(defun org-agenda-ng--todo-p (element &optional keywords)
  "Return non-nil if ELEMENT is a TODO item.
With KEYWORDS, return non-nil if its keyword is one of KEYWORDS."
  (when-let ((element-keyword (org-element-property :todo-keyword element)))
    (pcase keywords
      ('nil t)
      ((pred stringp)
       (string= element-keyword keywords))
      ((pred listp)
       (member element-keyword keywords))
      (otherwise (error "Invalid keyword argument: %s" otherwise)))))

(defun org-agenda-ng--date-p (entry type &optional comparator target-date)
  "Return non-nil if ENTRY has a date property of TYPE.
TYPE should be a keyword symbol, like :scheduled or :deadline.

With COMPARATOR and TARGET-DATE, return non-nil if entry's
scheduled date compares with TARGET-DATE according to COMPARATOR.
TARGET-DATE may be a string like \"2017-08-05\", or an integer
like one returned by `date-to-day'."
  (when-let ((entry-date (org-element-property type entry)))
    (pcase comparator
      ;; Not comparing, just checking if it has one
      ('nil t)
      ;; Compare dates
      ((and (pred functionp) (guard target-date))
       (let ((target-day-number (cl-typecase target-date
                                  ;; Append time to target-date
                                  ;; because `date-to-day' requires it
                                  (string (date-to-day (concat target-date " 00:00")))
                                  (integer target-date))))
         (pcase (org-element-property :type entry-date)
           ((or 'active 'inactive)
            (funcall comparator
                     (org-time-string-to-absolute
                      (org-element-timestamp-interpreter entry-date 'ignore))
                     target-day-number))
           (error "Unknown entry-date type: %s" (org-element-property :type entry-date)))))
      (otherwise (error "COMPARATOR (%s) must be a function, and DATE (%s) must be a string" comparator target-date)))))