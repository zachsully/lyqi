;;; Lexing and Parsing for emacs modes
;;; Mainly inspired by Drei component of McClim
;;;
;;; (c) copyright 2009 Nicolas Sceaux <nicolas.sceaux@free.fr>
;;; See http://nicolas.sceaux.free.fr/lilypond/

(eval-when-compile (require 'cl))
(require 'eieio)

;;;
;;; regex and match utilities
;;;

;; for XEmacs21 compatibility
(if (not (fboundp 'match-string-no-properties))
    (defalias 'match-string-no-properties 'match-string))

(defun lp:join (join-string strings)
  "Returns a concatenation of all strings elements, with join-string between elements"
  (apply 'concat 
	 (car strings) 
	 (mapcar (lambda (str) (concat join-string str))
		 (cdr strings))))

(defun lp:sort-string-by-length (string-list)
  "Sort the given string list by decreasing string length."
  (nreverse 
   (sort string-list
	 (lambda (str1 str2)
	   (or (< (length str1) (length str2))
	       (and (= (length str1) (length str2))
		    (string< str1 str2)))))))

(defun lp:forward-match ()
  (forward-char (- (match-end 0) (match-beginning 0))))

;;;
;;; Buffer syntax
;;;
(defclass lp:syntax ()
  ((default-parser-state
     :initform nil
     :initarg :default-parser-state
     :accessor lp:default-parser-state)
   (first-line :initform nil
               :accessor lp:first-line)
   (last-line :initform nil
              :accessor lp:last-line)
   (current-line :initform nil
                 :accessor lp:current-line))
  :documentation "Base class for defining a buffer syntax, which
  instance shall be buffer-local.  It contains a double-linked
  list of lines, containing the parsed forms on each line of the
  buffer.")

(defvar lp:*current-syntax* nil
  "The current buffer syntax object")

(defun lp:current-syntax ()
  lp:*current-syntax*)

(defmethod object-print ((this lp:syntax) &rest strings)
  (format "#<%s>" (object-class this)))

;;;
;;; The "parse tree" of a buffer is represented as a double-linked
;;; list of lines, each line containing a list of forms, each form
;;; possibly containing lexemes
;;;

;;; Lines
(defclass lp:line-parse ()
  ((marker :initarg :marker
           :accessor lp:marker)
   (forms :initarg :forms
          :accessor lp:line-forms)
   (parser-state :initform nil
                 :initarg :parser-state)
   (previous-line :initform nil
                  :initarg :previous-line
                  :accessor lp:previous-line)
   (next-line :initform nil
              :initarg :next-line
              :accessor lp:next-line)))

(defmethod object-print ((this lp:line-parse) &rest strings)
  (format "#<%s [%s] %s forms>"
            (object-class this)
            (marker-position (lp:marker this))
            (length (lp:line-forms this))))

(defun lp:link-lines (first next)
  (when first
    (set-slot-value first 'next-line next))
  (when next
    (set-slot-value next 'previous-line first)))

;;; Base class for forms and lexemes
(defclass lp:parser-symbol ()
  ((marker :initform nil
           :initarg :marker
           :accessor lp:marker)
   (size :initform nil
         :initarg :size
         :accessor lp:size)
   (children :initarg :children
             :initform nil
             :accessor lp:children)))

(defmethod object-write ((this lp:parser-symbol) &optional comment)
  (let* ((marker (lp:marker this))
         (size (lp:size this))
         (start (and marker (marker-position marker)))
         (end (and marker size (+ start size))))
    (princ
     (format "#<%s [%s-%s] \"%s\""
             (object-class this)
             (or start "?") (or end "?")
             (buffer-substring-no-properties start end)))
    (mapcar (lambda (lexeme)
              (princ " ")
              (princ (object-class lexeme)))
            (lp:children this))
    (princ ">\n")))

(defmethod object-print ((this lp:parser-symbol) &rest strings)
  (let* ((marker (lp:marker this))
         (size (lp:size this))
         (start (and marker (marker-position marker)))
         (end (and marker size (+ start size))))
    (format "#<%s [%s-%s]>"
            (object-class this)
            (or start "?") (or end "?"))))

;;; Forms (produced by reducing lexemes)
(defclass lp:form (lp:parser-symbol) ())

;;; Lexemes (produced when lexing)
(defclass lp:lexeme (lp:parser-symbol) ())

(defclass lp:comment-lexeme (lp:lexeme) ())
(defclass lp:comment-delimiter-lexeme (lp:lexeme) ())
(defclass lp:string-lexeme (lp:lexeme) ())
(defclass lp:doc-lexeme (lp:lexeme) ())
(defclass lp:keyword-lexeme (lp:lexeme) ())
(defclass lp:builtin-lexeme (lp:lexeme) ())
(defclass lp:function-name-lexeme (lp:lexeme) ())
(defclass lp:variable-name-lexeme (lp:lexeme) ())
(defclass lp:type-lexeme (lp:lexeme) ())
(defclass lp:constant-lexeme (lp:lexeme) ())
(defclass lp:warning-lexeme (lp:lexeme) ())
(defclass lp:negation-char-lexeme (lp:lexeme) ())
(defclass lp:preprocessor-lexeme (lp:lexeme) ())

(defclass lp:delimiter-lexeme (lp:lexeme) ())
(defclass lp:opening-delimiter-lexeme (lp:delimiter-lexeme) ())
(defclass lp:closing-delimiter-lexeme (lp:delimiter-lexeme) ())

(defmethod lp:opening-delimiter-p ((this lp:parser-symbol))
  nil)
(defmethod lp:opening-delimiter-p ((this lp:opening-delimiter-lexeme))
  t)
(defmethod lp:closing-delimiter-p ((this lp:parser-symbol))
  nil)
(defmethod lp:closing-delimiter-p ((this lp:closing-delimiter-lexeme))
  t)

;;; Parsing data (used when reducing lexemes to produce forms)
(defclass lp:parser-state ()
  ((lexemes :initarg :lexemes
            :initform nil)
   (form-class :initarg :form-class)
   (next-parser-state :initarg :next-parser-state
                      :initform nil
                      :accessor lp:next-parser-state)))

(defmethod lp:push-lexeme ((this lp:parser-state) lexeme)
  (set-slot-value this 'lexemes
                  (cons lexeme (slot-value this 'lexemes))))

(defmethod lp:reduce-lexemes ((this lp:parser-state) &optional form-class)
  (let ((reversed-lexemes (slot-value this 'lexemes)))
    (when reversed-lexemes
      (let* ((last-lexeme (first reversed-lexemes))
             (lexemes (nreverse (slot-value this 'lexemes)))
             (first-lexeme (first lexemes)))
        (set-slot-value this 'lexemes nil)
        (make-instance (or form-class (slot-value this 'form-class))
                       :children lexemes
                       :marker (lp:marker first-lexeme)
                       :size (- (+ (lp:marker last-lexeme)
                                   (lp:size last-lexeme))
                                (lp:marker first-lexeme)))))))

(defmethod lp:same-parser-state-p ((this lp:parser-state) other-state)
  (and other-state
       (eql (object-class this)
            (object-class other-state))
       (let ((next-class (and (lp:next-parser-state this)
                              (object-class (lp:next-parser-state this))))
             (other-next-class (and (lp:next-parser-state other-state)
                                    (object-class (lp:next-parser-state other-state)))))
         (eql next-class other-next-class))))

(defmethod lp:change-parser-state ((original lp:parser-state) new-class)
  (with-slots (lexemes form-class next-parser-state) original
    (make-instance new-class
                   :lexemes lexemes
                   :form-class form-class
                   :next-parser-state next-parser-state)))

;;;
;;; Lex function
;;;

(defgeneric lp:lex (parser-state syntax)
  "Lex or parse one element.

Depending on `parser-state' and the text at current point, either
lex a lexeme, or reduce previous lexemes (accumulated up to now
in `parser-state') to build a form, or both.

Return three values:
- the new parser state. The input `parser-state' may be modified,
  in particular its `lexemes' slot;
- a list of forms, if lexemes have been reduced, or NIL otherwise;
- NIL if the line parsing is finished, T otherwise.")

;; a default implementation to avoid compilation warnings
(defmethod lp:lex (parser-state syntax)
  (when (looking-at "[ \t]+")
    (lp:forward-match))
  (if (eolp)
      (values parser-state nil nil)
      (let ((marker (point-marker)))
        (looking-at "\\S-+")
        (lp:forward-match)
        (values parser-state
                (list (make-instance 'lp:form
                                     :marker marker
                                     :size (- (point) marker)))
                (not (eolp))))))

;;;
;;; Parse functions
;;;

(defun lp:parse (syntax &rest cl-keys)
  "Parse lines in current buffer from point up to `end-position'.
Return three values: the first parse line, the last parse
line (i.e. both ends of double linked parse line list.), and the
lexer state applicable to the following line.

Keywords supported:
  :parser-state (lp:default-parser-state syntax)
  :end-position (point-max)"
  (cl-parsing-keywords ((:parser-state (lp:default-parser-state syntax))
                        (:end-position (point-max))) ()
    (loop with result = nil
          with first-line = nil
          for previous-line = nil then line
          for parser-state = cl-parser-state then next-parser-state
          for marker = (let ((marker (point-marker)))
                         (set-marker-insertion-type marker nil)
                         marker)
          for (forms next-parser-state) = (lp:parse-line syntax parser-state)
          for line = (make-instance 'lp:line-parse
                                    :marker marker
                                    :previous-line previous-line
                                    :parser-state parser-state
                                    :forms forms)
          unless first-line do (setf first-line line)
          if previous-line do (set-slot-value previous-line 'next-line line)
          do (forward-line 1) ;; go to next-line
          if (>= (point) cl-end-position) return (values first-line line next-parser-state))))

(defun lp:parse-line (syntax parser-state)
  "Return a form list, built by parsing current buffer starting
from current point up to the end of the current line."
  (loop with end-point = (point-at-eol)
        for finished = nil then (>= (point) end-point)
        for (new-parser-state forms continue)
        = (lp:lex (or parser-state (lp:default-parser-state syntax)) syntax)
        then (lp:lex new-parser-state syntax)
        nconc forms into result
        while continue
        finally return (values result new-parser-state)))

;;;
;;; Parse search
;;;

(defun lp:find-lines (syntax position &optional length)
  "Search parse lines covering the region starting from
`position' and covering `length' (which defaults to 0). Return
two values: the first and the last parse line."
  ;; Compare the region position with the syntax current line (its
  ;; previously modified line, saved for quicker access), the first
  ;; line and the last line, to determine from which end start the
  ;; search.
  (let ((end-position (+ position (or length 0))))
    (multiple-value-bind (search-type from-line)
        (let ((current-line (lp:current-line syntax)))
          (if current-line
              (let* ((point-0/4 (point-min))
                     (point-4/4 (point-max))
                     (point-2/4 (lp:marker current-line))
                     (point-1/4 (/ (- point-2/4 point-0/4) 2))
                     (point-3/4 (/ (+ point-2/4 point-4/4) 2)))
                (cond ((<= point-3/4 end-position)
                       (values 'backward (lp:last-line syntax)))
                      ((<= position point-1/4)
                       (values 'forward (lp:first-line syntax)))
                      ((and (<= point-2/4 position) (<= position point-3/4))
                       (values 'forward current-line))
                      ((and (<= point-1/4 end-position) (<= end-position point-2/4))
                       (values 'backward current-line))
                      (t ;; (<= point-1/4 position point-1/2 end-position point-3/4)
                       (values 'both current-line))))
              (let* ((point-1/2 (/ (+ (point-max) (point-min)) 2)))
                (if (>= end-position point-1/2)
                    (values 'backward (lp:last-line syntax))
                    (values 'forward (lp:first-line syntax))))))
      (case search-type
        ((forward) ;; forward search from `from-line'
         (loop for line = from-line then (lp:next-line line)
               with first-line = nil
               if (and (not first-line)
                       (> (lp:marker line) position))
               do (setf first-line (lp:previous-line line))
               if (>= (lp:marker line) end-position)
               return (values (or first-line line) (lp:previous-line line))))
        ((backward) ;; backward search from `from-line'
         (loop for line = from-line then (lp:previous-line line)
               with last-found-line = nil
               if (and (not last-found-line)
                       (< (lp:marker line) end-position))
               do (setf last-found-line line)
               if (<= (lp:marker line) position) return (values line (or last-found-line line))))
        (t ;; search first line backward, and last-line forward from `from-line'
         (values (loop for line = from-line then (lp:previous-line)
                       if (<= (lp:marker line) position) return line)
                 (loop for line = from-line then (lp:next-line)
                       if (< (lp:marker line) end-position) return (lp:previous-line line))))))))

;;;
;;; Parse update
;;;

(defmacro lp:without-parse-update (&rest body)
  `(let ((after-change-functions nil))
     ,@body))
(put 'lp:without-parse-update 'lisp-indent-function 0)

(defun lp:parse-and-highlight-buffer ()
  "Make a full parse of current buffer and highlight text.  Set
current syntax parse data (`first-line' and `last-line' slots)."
  (let ((syntax (lp:current-syntax)))
    (lp:without-parse-update
      ;; initialize the parse tree
      (save-excursion
        (goto-char (point-min))
        (multiple-value-bind (first last state) (lp:parse syntax)
          (set-slot-value syntax 'first-line first)
          (set-slot-value syntax 'last-line last)))
      ;; fontify the buffer
      (loop for line = (lp:first-line syntax)
            then (lp:next-line line)
            while line
            do (mapcar #'lp:fontify (lp:line-forms line))))))

(defun lp:update-line-if-different-parser-state (line parser-state syntax)
  (when (and line
           (not (lp:same-parser-state-p
                 parser-state
                 (slot-value line 'parser-state))))
    (multiple-value-bind (forms next-state)
        (lp:parse-line syntax parser-state)
      (set-slot-value line 'forms forms)
      (set-slot-value line 'parser-state parser-state)
      (lp:fontify line)
      (forward-line 1)
      (lp:update-line-if-different-parser-state (lp:next-line line) next-state syntax))))

(defun lp:parse-update (beginning end old-length)
  "Update current syntax parse-tree after a buffer modification,
and fontify the changed text.

  `beginning' is the beginning of the changed text.
  `end' is the end of the changed text.
  `length' is the length the pre-changed text."
  (let ((syntax (lp:current-syntax)))
    (if (not (lp:first-line syntax))
        (lp:parse-and-highlight-buffer)
        ;; find the portion of the parse-tree that needs an update
        (multiple-value-bind (first-modified-line last-modified-line)
            (lp:find-lines syntax beginning old-length)
          (save-excursion
            (let ((end-position (progn
                                  (goto-char end)
                                  (point-at-eol))))
              (goto-char beginning)
              (forward-line 0)
              ;; re-parse the modified lines
              (multiple-value-bind (first-new-line last-new-line next-state)
                  (lp:parse syntax
                            :parser-state (slot-value first-modified-line 'parser-state)
                            :end-position end-position)
                ;; fontify new lines
                (loop for line = first-new-line then (lp:next-line line)
                      while line
                      do (mapcar #'lp:fontify (lp:line-forms line)))
                ;; replace the old lines with the new ones in the
                ;; double-linked list
                (if (eql (lp:first-line syntax) first-modified-line)
                    (set-slot-value syntax 'first-line first-new-line)
                    (lp:link-lines (lp:previous-line first-modified-line)
                                   first-new-line))
                (if (eql (lp:last-line syntax) last-modified-line)
                    (set-slot-value syntax 'last-line last-new-line)
                    (lp:link-lines last-new-line
                                   (lp:next-line last-modified-line)))
                ;; Update the syntax `current-line', from quick access
                (set-slot-value syntax 'current-line last-new-line)
                ;; If the lexer state at the end of last-new-line is
                ;; different from the lexer state at the beginning of
                ;; the next line, then parse next line again (and so
                ;; on)
                (lp:update-line-if-different-parser-state
                 (lp:next-line last-new-line) next-state syntax)
                ;; debug
                (princ (format "old: [%s-%s] new: [%s-%s]"
                               (marker-position (lp:marker first-modified-line))
                               (marker-position (lp:marker last-modified-line))
                               (marker-position (lp:marker first-new-line))
                               (marker-position (lp:marker last-new-line))))
                )))))))

;;;
;;; Fontification
;;;

(defgeneric lp:fontify (parser-symbol)
  "Fontify a lexeme or form")

(defgeneric lp:face (parser-symbol)
  "The face of a lexeme or form, used in fontification.")

(defmethod lp:fontify ((this lp:line-parse))
  (mapcar #'lp:fontify (lp:line-forms this)))

(defmethod lp:fontify ((this lp:parser-symbol))
  (let* ((start (marker-position (lp:marker this)))
         (end (+ start (lp:size this))))
    (when (> end start)
      (set-text-properties start end (lp:face this)))))

(defmethod lp:fontify ((this lp:form))
  (let ((children (slot-value this 'children)))
    (if children
        (mapcar 'lp:fontify children)
        (call-next-method))))

(defmethod lp:face ((this lp:parser-symbol))
  nil)

(defmethod lp:face ((this lp:comment-lexeme))
  '(face font-lock-comment-face))
(defmethod lp:face ((this lp:comment-delimiter-lexeme))
  '(face font-lock-comment-delimiter-face))
(defmethod lp:face ((this lp:string-lexeme))
  '(face font-lock-string-face))
(defmethod lp:face ((this lp:doc-lexeme))
  '(face font-lock-doc-face))
(defmethod lp:face ((this lp:keyword-lexeme))
  '(face font-lock-keyword-face))
(defmethod lp:face ((this lp:builtin-lexeme))
  '(face font-lock-builtin-face))
(defmethod lp:face ((this lp:function-name-lexeme))
  '(face font-lock-function-name-face))
(defmethod lp:face ((this lp:variable-name-lexeme))
  '(face font-lock-variable-name-face))
(defmethod lp:face ((this lp:type-lexeme))
  '(face font-lock-type-face))
(defmethod lp:face ((this lp:constant-lexeme))
  '(face font-lock-constant-face))
(defmethod lp:face ((this lp:warning-lexeme))
  '(face font-lock-warning-face))
(defmethod lp:face ((this lp:negation-char-lexeme))
  '(face font-lock-negation-char-face))
(defmethod lp:face ((this lp:preprocessor-lexeme))
  '(face font-lock-preprocessor-face))

;;;
(provide 'lp-base)