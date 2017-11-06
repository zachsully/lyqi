;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;
;;; Compilation commands
;;;

(eval-when-compile (require 'cl))

;;;
;;; Master file, used for compilation
;;; - if `lyqi:buffer-master-file' (which is buffer local) is non-NIL,
;;;   use its value;
;;; - if `lyqi:global-master-file' is non-NIL, use its value;
;;; - if curent-buffer is a .ly file, use this file.
;;;

(defvar lyqi:global-master-file nil
  "Master .ly file for LilyPond compilation (if
  `lyqi:buffer-master-file' is NIL).")

(defvar lyqi:buffer-master-file nil
  "Master .ly file for LilyPond compilation for current
  buffer (overrides `lyqi:global-master-file').")

(defun lyqi:master-file ()
  (let ((pathname (buffer-file-name)))
    (or (and (string-equal (file-name-extension pathname) "ly")
             pathname)
        lyqi:buffer-master-file
        lyqi:global-master-file)))

(defun lyqi:defined-master-file ()
  (and (not (string-equal (file-name-extension  (buffer-file-name)) "ly"))
       (or lyqi:buffer-master-file
           lyqi:global-master-file)))

(defun lyqi:set-buffer-master-file (filename)
  (interactive "fBuffer master file:")
  (setq lyqi:buffer-master-file filename))

(defun lyqi:set-global-master-file (filename)
  (interactive "fGlobal master file:")
  (setq lyqi:global-master-file filename))

(defun lyqi:unset-master-file ()
  (interactive "")
  (cond (lyqi:buffer-master-file
         (setq lyqi:buffer-master-file nil))
        (lyqi:global-master-file
         (setq lyqi:global-master-file nil))))

;;;
;;; LilyPond compilation
;;;

(defun command-string (command ext)
  (let* ((pathname (file-truename (lyqi:master-file)))
           (directory (file-name-directory pathname))
           (basename (file-name-sans-extension (file-name-nondirectory pathname))))
    (format "cd %s; %s %s.%s"
            (shell-quote-argument directory)
            command
            (shell-quote-argument basename)
            ext)))

(defun lyqi:compile-ly ()
  (interactive)
  (start-process-shell-command
   "lyqi-compile"
   "*lyqi-compile*"
   (command-string lyqi:lilypond-command "ly"))
  (display-buffer-at-bottom
   (get-buffer-create "*lyqi-compile*")
   '((window-height . 10))))

(defun lyqi:open-pdf ()
  (interactive)
  (start-process-shell-command
   "lyqi-pdf"
   nil
   (command-string lyqi:pdf-command "pdf")))

(defun lyqi:open-midi ()
  (interactive)
  (start-process-shell-command
   "lyqi-midi"
   "*lyqi-midi*"
   (command-string lyqi:midi-command "midi"))
  (display-buffer-at-bottom
   (get-buffer-create "*lyqi-compile*")
   '((window-height . 10))))

(provide 'lyqi-compile-commands)
