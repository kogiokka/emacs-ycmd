;;; ycmd.el --- emacs bindings to the ycmd completion server -*- lexical-binding: t -*-
;;
;; Copyright (c) 2014-2016 Austin Bingham, Peter Vasil
;;
;; Authors: Austin Bingham <austin.bingham@gmail.com>
;;          Peter Vasil <mail@petervasil.net>
;; Version: 0.9.1
;; URL: https://github.com/abingham/emacs-ycmd
;; Package-Requires: ((emacs "24") (f "0.17.1") (dash "1.2.0") (deferred "0.3.2") (popup "0.5.0") (cl-lib "0.5"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;; Description:
;;
;; ycmd is a modular server that provides completion for C/C++/ObjC
;; and Python, among other languages. This module provides an emacs
;; client for that server.
;;
;; ycmd is a bit peculiar in a few ways. First, communication with the
;; server uses HMAC to authenticate HTTP messages. The server is
;; started with an HMAC secret that the client uses to generate hashes
;; of the content it sends. Second, the server gets this HMAC
;; information (as well as other configuration information) from a
;; file that the server deletes after reading. So when the code in
;; this module starts a server, it has to create a file containing the
;; secret code. Since the server deletes this file, this code has to
;; create a new one for each server it starts. Hopefully by knowing
;; this, you'll be able to make more sense of some of what you see
;; below.
;;
;; For more details, see the project page at
;; https://github.com/abingham/emacs-ycmd.
;;
;; Installation:
;;
;; Copy this file to to some location in your emacs load path. Then add
;; "(require 'ycmd)" to your emacs initialization (.emacs,
;; init.el, or something).
;;
;; Example config:
;;
;;   (require 'ycmd)
;;   (ycmd-setup)
;;
;; Basic usage:
;;
;; First you'll want to configure a few things. If you've got a global
;; ycmd config file, you can specify that with `ycmd-global-config':
;;
;;   (set-variable 'ycmd-global-config "/path/to/global_conf.py")
;;
;; Then you'll want to configure your "extra-config whitelist"
;; patterns. These patterns determine which extra-conf files will get
;; loaded automatically by ycmd. So, for example, if you want to make
;; sure that ycmd will automatically load all of the extra-conf files
;; underneath your "~/projects" directory, do this:
;;
;;   (set-variable 'ycmd-extra-conf-whitelist '("~/projects/*"))
;;
;; Now, the first time you open a file for which ycmd can perform
;; completions, a ycmd server will be automatically started.
;;
;; When ycmd encounters an extra-config that's not on the white list,
;; it checks `ycmd-extra-conf-handler' to determine what to do. By
;; default this is set to `ask', in which case the user is asked
;; whether to load the file or ignore it. You can also set it to
;; `load', in which case all extra-confs are loaded (and you don't
;; really need to worry about `ycmd-extra-conf-whitelist'.) Or you can
;; set this to `ignore', in which case all extra-confs are
;; automatically ignored.
;;
;; Use `ycmd-get-completions' to get completions at some point in a
;; file. For example:
;;
;;   (ycmd-get-completions buffer position)
;;
;; You can use `ycmd-display-completions' to toy around with completion
;; interactively and see the shape of the structures in use.
;;
;;; License:
;;
;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this software and associated documentation
;; files (the "Software"), to deal in the Software without
;; restriction, including without limitation the rights to use, copy,
;; modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'dash)
(require 'deferred)
(require 'f)
(require 'hmac-def)
(require 'json)
(require 'popup)
;; (require 'request)
;; (require 'request-deferred)
(require 'etags)

;; Allow loading of our bundled third-party modules
(add-to-list 'load-path (f-join (f-dirname (f-this-file)) "third-party"))

(require 'ycmd-request)
(require 'ycmd-request-deferred)

(defgroup ycmd nil
  "a ycmd emacs client"
  :link '(url-link :tag "Github" "https://github.com/abingham/emacs-ycmd")
  :group 'tools
  :group 'programming)

(defcustom ycmd-global-config nil
  "Path to global extra conf file."
  :type '(string)
  :group 'ycmd)

(defcustom ycmd-extra-conf-whitelist nil
  "List of glob expressions which match extra configs.
Whitelisted configs are loaded without confirmation."
  :type '(repeat string)
  :group 'ycmd)

(defcustom ycmd-extra-conf-handler 'ask
  "What to do when an un-whitelisted extra config is encountered.

Options are:

`load'
      Automatically load unknown extra confs.

`ignore'
     Ignore unknown extra confs and do not load them.

`ask'
     Ask the user for each unknown extra conf."
  :group 'ycmd
  :type '(choice (const :tag "Load unknown extra confs" load)
                 (const :tag "Ignore unknown extra confs" ignore)
                 (const :tag "Ask the user" ask))
  :risky t)

(defcustom ycmd-host "127.0.0.1"
  "The host on which the ycmd server is running."
  :type '(string)
  :group 'ycmd)

; TODO: Figure out the best default value for this.
(defcustom ycmd-server-command '("python" "/path/to/ycmd/package/")
  "The ycmd server program command.

Note that the default value for this variable is intentionally
incorrect.  You will almost certainly need to set it to match your
system installation."
  :type '(repeat string)
  :group 'ycmd)

(defcustom ycmd-server-args '("--log=debug"
                              "--keep_logfile"
                              "--idle_suicide_seconds=10800")
  "Extra arguments to pass to the ycmd server."
  :type '(repeat string)
  :group 'ycmd)

(defcustom ycmd-file-parse-result-hook nil
  "Functions to run with file-parse results.

Each function will be called with with the results returned from
ycmd when it parses a file in response to
/event_notification.  See `ycmd--with-destructured-parse-result'
for some insight into what this structure is shaped like."
  :group 'ycmd
  :type 'hook
  :risky t)

(defcustom ycmd-idle-change-delay 0.5
  "Number of seconds to wait after buffer modification before
re-parsing the contents."
  :group 'ycmd
  :type '(number)
  :safe #'numberp)

(defcustom ycmd-keepalive-period 30
  "Number of seconds between keepalive messages."
  :group 'ycmd
  :type '(number))

(defcustom ycmd-startup-timeout 3
  "Number of seconds to wait for the server to start."
  :group 'ycmd
  :type '(number))

(defcustom ycmd-delete-process-delay 3
  "Seconds to wait for the server to finish before killing the process."
  :group 'ycmd
  :type '(number))

(defcustom ycmd-parse-conditions '(save new-line mode-enabled)
  "When ycmd should reparse the buffer.

The variable is a list of events that may trigger parsing the
buffer for new completion:

`save'
      Set buffer-needs-parse flag after the buffer was saved.

`new-line'
      Set buffer-needs-parse flag immediately after a new
      line was inserted into the buffer.

`idle-change'
      Set buffer-needs-parse flag a short time after a
      buffer has changed.  (See `ycmd-idle-change-delay')

`mode-enabled'
      Set buffer-needs-parse flag after `ycmd-mode' has been
      enabled.

`buffer-focus'
      Set buffer-needs-parse flag when an unparsed buffer gets
      focus.

If nil, never set buffer-needs-parse flag.  For a manual reparse,
use `ycmd-parse-buffer'."
  :group 'ycmd
  :type '(set (const :tag "After the buffer was saved" save)
              (const :tag "After a new line was inserted" new-line)
              (const :tag "After a buffer was changed and idle" idle-change)
              (const :tag "After a `ycmd-mode' was enabled" mode-enabled)
              (const :tag "After an unparsed buffer gets focus" buffer-focus))
  :safe #'listp)

(defcustom ycmd-default-tags-file-name "tags"
  "The default tags file name."
  :group 'ycmd
  :type 'string)

(defcustom ycmd-force-semantic-completion nil
  "Whether to use always semantic completion."
  :group 'ycmd
  :type 'boolean)

(defcustom ycmd-hide-url-status t
  "Whether to quash url status messages for ycmd requests."
  :group 'ycmd
  :type 'boolean)

(defcustom ycmd-bypass-url-proxy-services t
  "Bypass proxies for local traffic with the ycmd server.

If non-nil, bypass the variable `url-proxy-services' in
`ycmd--request' by setting it to nil."
  :group 'ycmd
  :type 'boolean)

(defcustom ycmd-tag-files nil
  "Whether to collect identifiers from tags file.

nil
    Do not collect identifiers from tag files.

`auto'
    Look up directory hierarchy for first found tags file with
    `ycmd-default-tags-file-name'.

string
    A tags file name.

list
    A list of tag file names."
  :group 'ycmd
  :type '(choice (const :tag "Don't use tag file." nil)
                 (const :tag "Locate tags file automatically" auto)
                 (string :tag "Tag file name")
                 (repeat :tag "List of tag files"
                         (string :tag "Tag file name")))
  :safe (lambda (obj)
          (or (symbolp obj)
              (stringp obj)
              (ycmd--string-list-p obj))))

(defcustom ycmd-file-type-map
  '((c++-mode . ("cpp"))
    (c-mode . ("c"))
    (caml-mode . ("ocaml"))
    (csharp-mode . ("cs"))
    (d-mode . ("d"))
    (erlang-mode . ("erlang"))
    (go-mode . ("go"))
    (js-mode . ("javascript"))
    (js2-mode . ("javascript"))
    (lua-mode . ("lua"))
    (objc-mode . ("objc"))
    (perl-mode . ("perl"))
    (cperl-mode . ("perl"))
    (php-mode . ("php"))
    (python-mode . ("python"))
    (ruby-mode . ("ruby"))
    (rust-mode . ("rust"))
    (scala-mode . ("scala"))
    (tuareg-mode . ("ocaml")))
  "Mapping from major modes to ycmd file-type strings.

Used to determine a) which major modes we support and b) how to
describe them to ycmd."
  :group 'ycmd
  :type '(alist :key-type symbol :value-type (repeat string)))

(defcustom ycmd-min-num-chars-for-completion 2
  "The minimum number of characters for identifier completion.

It controls the number of characters the user needs to type
before identifier-based completion suggestions are triggered.

This option is NOT used for semantic completion.

Setting this it to a high number like 99 effectively turns off
the identifier completion engine and just leaves the semantic
engine."
  :group 'ycmd
  :type 'integer)

(defcustom ycmd-max-num-identifier-candidates 10
  "The maximum number of identifier completion results."
  :group 'ycmd
  :type 'integer)

(defcustom ycmd-seed-identifiers-with-keywords nil
  "Whether to seed identifier database with keywords."
  :group 'ycmd
  :type 'boolean)

(defcustom ycmd-get-keywords-function 'ycmd--get-keywords-from-alist
  "Function to get keywords for current mode."
  :group 'ycmd
  :type 'symbol)

(defcustom ycmd-gocode-binary-path nil
  "Gocode binary path."
  :group 'ycmd
  :type 'string)

(defcustom ycmd-godef-binary-path nil
  "Godef binary path."
  :group 'ycmd
  :type 'string)

(defcustom ycmd-rust-src-path nil
  "Rust source path."
  :group 'ycmd
  :type 'string)

(defcustom ycmd-racerd-binary-path nil
  "Racerd binary path."
  :group 'ycmd
  :type 'string)

(defcustom ycmd-python-binary-path nil
  "Python binary path."
  :group 'ycmd
  :type 'string)

(defcustom ycmd-global-modes t
  "Modes for which `ycmd-mode' is turned on by `global-ycmd-mode'.

If t, ycmd mode is turned on for all major modes in
`ycmd-file-type-map'.  If set to all, ycmd mode is turned on
for all major-modes.  If a list, ycmd mode is turned on for all
`major-mode' symbols in that list.  If the `car' of the list is
`not', ycmd mode is turned on for all `major-mode' symbols _not_
in that list.  If nil, ycmd mode is never turned on by
`global-ycmd-mode'."
  :group 'ycmd
  :type '(choice (const :tag "none" nil)
                 (const :tag "member in `ycmd-file-type-map'" t)
                 (const :tag "all" all)
                 (set :menu-tag "mode specific" :tag "modes"
                      :value (not)
                      (const :tag "Except" not)
                      (repeat :inline t (symbol :tag "mode")))))

(defcustom ycmd-confirm-fixit t
  "Whether to confirm when applying fixit on line."
  :group 'ycmd
  :type 'boolean)

(defconst ycmd--diagnostic-file-types
  '("c"
    "cpp"
    "objc"
    "objcpp"
    "cs")
  "A list of ycmd file type strings which support semantic completion.")

(defvar ycmd-keywords-alist
  '((c++-mode
     "alignas" "alignof" "and" "and_eq" "asm" "auto" "bitand" "bitor" "bool"
     "break" "case" "catch" "char" "char16_t" "char32_t" "class" "compl"
     "concept" "const" "const_cast" "constexpr" "continue" "decltype" "default"
     "define" "defined" "delete" "do" "double" "dynamic_cast" "elif" "else"
     "endif" "enum" "error" "explicit" "export" "extern" "false" "final" "float"
     "for" "friend" "goto" "if" "ifdef" "ifndef" "include" "inline" "int" "line"
     "long" "mutable" "namespace" "new" "noexcept" "not" "not_eq" "nullptr"
     "operator" "or" "or_eq" "override" "pragma" "_Pragma" "private" "protected"
     "public" "register" "reinterpret_cast" "requires" "return" "short" "signed"
     "sizeof" "static" "static_assert" "static_cast" "struct" "switch"
     "template" "this" "thread_local" "throw" "true" "try" "typedef" "typeid"
     "typename" "union" "unsigned" "using" "virtual" "void" "volatile" "wchar_t"
     "while" "xor" "xor_eq")
    (c-mode
     "auto" "_Alignas" "_Alignof" "_Atomic" "_Bool" "break" "case" "char"
     "_Complex" "const" "continue" "default" "define" "defined" "do" "double"
     "elif" "else" "endif" "enum" "error" "extern" "float" "for" "goto"
     "_Generic" "if" "ifdef" "ifndef" "_Imaginary" "include" "inline" "int"
     "line" "long" "_Noreturn" "pragma" "register" "restrict" "return" "short"
     "signed" "sizeof" "static" "struct" "switch" "_Static_assert" "typedef"
     "_Thread_local" "undef" "union" "unsigned" "void" "volatile" "while")
    (go-mode
     "break" "case" "chan" "const" "continue" "default" "defer" "else"
     "fallthrough" "for" "func" "go" "goto" "if" "import" "interface" "map"
     "package" "range" "return" "select" "struct" "switch" "type" "var")
    (lua-mode
     "and" "break" "do" "else" "elseif" "end" "false" "for" "function" "if" "in"
     "local" "nil" "not" "or" "repeat" "return" "then" "true" "until" "while")
    (python-mode
     "ArithmeticError" "AssertionError" "AttributeError" "BaseException"
     "BufferError" "BytesWarning" "DeprecationWarning" "EOFError" "Ellipsis"
     "EnvironmentError" "Exception" "False" "FloatingPointError" "FutureWarning"
     "GeneratorExit" "IOError" "ImportError" "ImportWarning" "IndentationError"
     "IndexError" "KeyError" "KeyboardInterrupt" "LookupError" "MemoryError"
     "NameError" "None" "NotImplemented" "NotImplementedError" "OSError"
     "OverflowError" "PendingDeprecationWarning" "ReferenceError" "RuntimeError"
     "RuntimeWarning" "StandardError" "StopIteration" "SyntaxError"
     "SyntaxWarning" "SystemError" "SystemExit" "TabError" "True" "TypeError"
     "UnboundLocalError" "UnicodeDecodeError" "UnicodeEncodeError"
     "UnicodeError" "UnicodeTranslateError" "UnicodeWarning" "UserWarning"
     "ValueError" "Warning" "ZeroDivisionError" "__builtins__" "__debug__"
     "__doc__" "__file__" "__future__" "__import__" "__init__" "__main__"
     "__name__" "__package__" "_dummy_thread" "_thread" "abc" "abs" "aifc" "all"
     "and" "any" "apply" "argparse" "array" "as" "assert" "ast" "asynchat"
     "asyncio" "asyncore" "atexit" "audioop" "base64" "basestring" "bdb" "bin"
     "binascii" "binhex" "bisect" "bool" "break" "buffer" "builtins" "bytearray"
     "bytes" "bz2" "calendar" "callable" "cgi" "cgitb" "chr" "chuck" "class"
     "classmethod" "cmath" "cmd" "cmp" "code" "codecs" "codeop" "coerce"
     "collections" "colorsys" "compile" "compileall" "complex" "concurrent"
     "configparser" "contextlib" "continue" "copy" "copyreg" "copyright"
     "credits" "crypt" "csv" "ctypes" "curses" "datetime" "dbm" "decimal" "def"
     "del" "delattr" "dict" "difflib" "dir" "dis" "distutils" "divmod" "doctest"
     "dummy_threading" "elif" "else" "email" "enumerate" "ensurepip" "enum"
     "errno" "eval" "except" "exec" "execfile" "exit" "faulthandler" "fcntl"
     "file" "filecmp" "fileinput" "filter" "finally" "float" "fnmatch" "for"
     "format" "formatter" "fpectl" "fractions" "from" "frozenset" "ftplib"
     "functools" "gc" "getattr" "getopt" "getpass" "gettext" "glob" "global"
     "globals" "grp" "gzip" "hasattr" "hash" "hashlib" "heapq" "help" "hex"
     "hmac" "html" "http" "id" "if" "imghdr" "imp" "impalib" "import"
     "importlib" "in" "input" "inspect" "int" "intern" "io" "ipaddress" "is"
     "isinstance" "issubclass" "iter" "itertools" "json" "keyword" "lambda"
     "len" "license" "linecache" "list" "locale" "locals" "logging" "long"
     "lzma" "macpath" "mailbox" "mailcap" "map" "marshal" "math" "max"
     "memoryview" "mimetypes" "min" "mmap" "modulefinder" "msilib" "msvcrt"
     "multiprocessing" "netrc" "next" "nis" "nntplib" "not" "numbers" "object"
     "oct" "open" "operator" "optparse" "or" "ord" "os" "ossaudiodev" "parser"
     "pass" "pathlib" "pdb" "pickle" "pickletools" "pipes" "pkgutil" "platform"
     "plistlib" "poplib" "posix" "pow" "pprint" "print" "profile" "property"
     "pty" "pwd" "py_compiler" "pyclbr" "pydoc" "queue" "quit" "quopri" "raise"
     "random" "range" "raw_input" "re" "readline" "reduce" "reload" "repr"
     "reprlib" "resource" "return" "reversed" "rlcompleter" "round" "runpy"
     "sched" "select" "selectors" "self" "set" "setattr" "shelve" "shlex"
     "shutil" "signal" "site" "slice" "smtpd" "smtplib" "sndhdr" "socket"
     "socketserver" "sorted" "spwd" "sqlite3" "ssl" "stat" "staticmethod"
     "statistics" "str" "string" "stringprep" "struct" "subprocess" "sum"
     "sunau" "super" "symbol" "symtable" "sys" "sysconfig" "syslog" "tabnanny"
     "tarfile" "telnetlib" "tempfile" "termios" "test" "textwrap" "threading"
     "time" "timeit" "tkinter" "token" "tokenize" "trace" "traceback"
     "tracemalloc" "try" "tty" "tuple" "turtle" "type" "types" "unichr"
     "unicode" "unicodedata" "unittest" "urllib" "uu" "uuid" "vars" "venv"
     "warnings" "wave" "weakref" "webbrowser" "while" "winsound" "winreg" "with"
     "wsgiref" "xdrlib" "xml" "xmlrpc" "xrange" "yield" "zip" "zipfile" "zipimport"
     "zlib"))
  "Alist mapping major-modes to keywords for.

Keywords source: https://github.com/auto-complete/auto-complete/tree/master/dict")

(defvar ycmd--server-actual-port 0
  "The actual port being used by the ycmd server.
This is set based on the output from the server itself.")

(defvar ycmd--hmac-secret nil
  "This is populated with the hmac secret of the current connection.
Users should never need to modify this, hence the defconst.  It is
not, however, treated as a constant by this code.  This value
gets set in ycmd-open.")

(defconst ycmd--server-process-name "ycmd-server"
  "The Emacs name of the server process.
This is used by functions like `start-process', `get-process'
and `delete-process'.")

(defvar-local ycmd--notification-timer nil
  "Timer for notifying ycmd server to do work, e.g. parsing files.")

(defvar ycmd--keepalive-timer nil
  "Timer for sending keepalive messages to the server.")

(defvar ycmd--on-focus-timer nil
  "Timer for deferring ycmd server notification to parse a buffer.")

(defconst ycmd--server-buffer-name "*ycmd-server*"
  "Name of the ycmd server buffer.")

(defvar-local ycmd--last-status-change 'unparsed
  "The last status of the current buffer.")

(defvar ycmd--mode-keywords-loaded nil
  "List of modes for which keywords have been loaded.")

(defconst ycmd-hooks-alist
  '((after-save-hook                  . ycmd--on-save)
    (after-change-functions           . ycmd--on-change)
    (window-configuration-change-hook . ycmd--on-window-configuration-change)
    (kill-buffer-hook                 . ycmd--teardown)
    (before-revert-hook               . ycmd--teardown))
  "Hooks which ycmd hooks in.")

(add-hook 'kill-emacs-hook 'ycmd-close)

(defvar ycmd-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map "p" 'ycmd-parse-buffer)
    (define-key map "o" 'ycmd-open)
    (define-key map "c" 'ycmd-close)
    (define-key map "." 'ycmd-goto)
    (define-key map "gi" 'ycmd-goto-include)
    (define-key map "gd" 'ycmd-goto-definition)
    (define-key map "gD" 'ycmd-goto-declaration)
    (define-key map "gm" 'ycmd-goto-implementation)
    (define-key map "gp" 'ycmd-goto-imprecise)
    (define-key map "gr" 'ycmd-goto-references)
    (define-key map "s" 'ycmd-toggle-force-semantic-completion)
    (define-key map "v" 'ycmd-show-debug-info)
    (define-key map "d" 'ycmd-show-documentation)
    (define-key map "C" 'ycmd-clear-compilation-flag-cache)
    (define-key map "t" 'ycmd-get-type)
    (define-key map "T" 'ycmd-get-parent)
    (define-key map "f" 'ycmd-fixit)
    map)
  "Keymap for `ycmd-mode' interactive commands.")

(defcustom ycmd-keymap-prefix (kbd "C-c Y")
  "Prefix for key bindings of `ycmd-mode'.

Changing this variable outside Customize does not have any
effect.  To change the keymap prefix from Lisp, you need to
explicitly re-define the prefix key:

    (define-key ycmd-mode-map ycmd-keymap-prefix nil)
    (setq ycmd-keymap-prefix (kbd \"C-c ,\"))
    (define-key ycmd-mode-map ycmd-keymap-prefix
                ycmd-command-map)"
  :group 'ycmd
  :type 'string
  :risky t
  :set
  (lambda (variable key)
    (when (and (boundp variable) (boundp 'ycmd-mode-map))
      (define-key ycmd-mode-map (symbol-value variable) nil)
      (define-key ycmd-mode-map key ycmd-command-map))
    (set-default variable key)))

(defvar ycmd-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map ycmd-keymap-prefix ycmd-command-map)
    map)
  "Keymap for `ycmd-mode'.")

(defmacro ycmd--kill-timer (timer)
  "Cancel TIMER."
  `(when ,timer
     (cancel-timer ,timer)
     (setq ,timer nil)))

(defun ycmd-parsing-in-progress-p ()
  "Return t if parsing is in progress."
  (eq ycmd--last-status-change 'parsing))

(defun ycmd--report-status (status)
  "Report ycmd STATUS."
  (setq ycmd--last-status-change status)
  (force-mode-line-update))

(defun ycmd--mode-line-status-text ()
  "Get text for the mode line."
  (let ((force-semantic
         (when ycmd-force-semantic-completion "/s"))
        (text (pcase ycmd--last-status-change
                (`unparsed "?")
                (`parsing "*")
                (`errored "!")
                (`parsed ""))))
    (concat " ycmd" force-semantic text)))

;;;###autoload
(define-minor-mode ycmd-mode
  "Minor mode for interaction with the ycmd completion server.

When called interactively, toggle `ycmd-mode'.  With prefix ARG,
enable `ycmd-mode' if ARG is positive, otherwise disable it.

When called from Lisp, enable `ycmd-mode' if ARG is omitted,
nil or positive.  If ARG is `toggle', toggle `ycmd-mode'.
Otherwise behave as if called interactively.

\\{ycmd-mode-map}"
  :init-value nil
  :keymap ycmd-mode-map
  :lighter (:eval (ycmd--mode-line-status-text))
  :group 'ycmd
  :require 'ycmd
  :after-hook (ycmd--conditional-parse 'mode-enabled)
  (cond
   (ycmd-mode
    (dolist (hook ycmd-hooks-alist)
      (add-hook (car hook) (cdr hook) nil 'local)))
   (t
    (dolist (hook ycmd-hooks-alist)
      (remove-hook (car hook) (cdr hook) 'local))
    (ycmd--teardown))))

;;;###autoload
(defun ycmd-setup ()
  "Setup `ycmd-mode'.

Hook `ycmd-mode' into modes in `ycmd-file-type-map'."
  (interactive)
  (dolist (it ycmd-file-type-map)
    (add-hook (intern (format "%s-hook" (symbol-name (car it)))) 'ycmd-mode)))
(make-obsolete 'ycmd-setup 'global-ycmd-mode "0.9.1")

(defun ycmd--maybe-enable-mode ()
  "Enable `ycmd-mode' according `ycmd-global-modes'."
  (when (pcase ycmd-global-modes
          (`t (ycmd-major-mode-to-file-types major-mode))
          (`all t)
          (`(not . ,modes) (not (memq major-mode modes)))
          (modes (memq major-mode modes)))
    (ycmd-mode)))

;;;###autoload
(define-globalized-minor-mode global-ycmd-mode ycmd-mode
  ycmd--maybe-enable-mode
  :init-value nil)


(defun ycmd--conditional-parse (&optional condition)
  "Reparse the buffer under CONDITION.

If CONDITION is non-nil, determine whether a ready to parse
notification should be sent according `ycmd-parse-conditions'."
  (when (and ycmd-mode
             (or (not condition)
                 (memq condition ycmd-parse-conditions)))
    (ycmd-notify-file-ready-to-parse)))

(defun ycmd--on-save ()
  "Function to run when the buffer has been saved."
  (ycmd--conditional-parse 'save))

(defun ycmd--on-idle-change ()
  "Function to run on idle-change."
  (ycmd--kill-timer ycmd--notification-timer)
  (ycmd--conditional-parse 'idle-change))

(defun ycmd--on-change (beg end _len)
  "Function to run when a buffer change between BEG and END.
_LEN is ununsed."
  (save-match-data
    (when ycmd-mode
      (ycmd--kill-timer ycmd--notification-timer)
      (if (string-match-p "\n" (buffer-substring beg end))
          (ycmd--conditional-parse 'new-line)
        (setq ycmd--notification-timer
              (run-at-time ycmd-idle-change-delay nil
                           #'ycmd--on-idle-change))))))

(defun ycmd--on-unparsed-buffer-focus ()
  "Function to run when an unparsed buffer gets focus."
  (ycmd--kill-timer ycmd--on-focus-timer)
  (ycmd--conditional-parse 'buffer-focus))

(defun ycmd--on-window-configuration-change ()
  "Function to run by `window-configuration-change-hook'."
  (when (and ycmd-mode
             (eq ycmd--last-status-change 'unparsed)
             (memq 'buffer-focus ycmd-parse-conditions))
    (ycmd--kill-timer ycmd--on-focus-timer)
    (setq ycmd--on-focus-timer
          (run-at-time 1.0 nil #'ycmd--on-unparsed-buffer-focus))))

(defmacro ycmd--with-all-ycmd-buffers (&rest body)
  "Execute BODY with each `ycmd-mode' enabled buffer."
  (declare (indent 0) (debug t))
  `(dolist (buffer (buffer-list))
     (with-current-buffer buffer
       (when ycmd-mode
         ,@body))))

(defun ycmd--teardown ()
  "Teardown ycmd in current buffer."
  (ycmd--kill-timer ycmd--notification-timer)
  (setq ycmd--last-status-change 'unparsed))

(defun ycmd--global-teardown ()
  "Teardown ycmd in all buffers."
  (ycmd--kill-timer ycmd--on-focus-timer)
  (setq ycmd--mode-keywords-loaded nil)
  (ycmd--with-all-ycmd-buffers (ycmd--teardown)))

(defun ycmd-diagnostic-file-types (mode)
  "Find the ycmd file types for MODE which support semantic completion.

Returns a possibly empty list of ycmd file type strings.  If this
is empty, then ycmd doesn't support semantic completion (or
diagnostics) for MODE."
  (-intersection
   ycmd--diagnostic-file-types
   (ycmd-major-mode-to-file-types mode)))

(defun ycmd-open ()
  "Start a new ycmd server.

This kills any ycmd server already running (under ycmd.el's
control.) The newly started server will have a new HMAC secret."
  (interactive)

  (ycmd-close)

  (let ((hmac-secret (ycmd--generate-hmac-secret)))
    (ycmd--start-server hmac-secret)
    (setq ycmd--hmac-secret hmac-secret))

  (ycmd--start-keepalive-timer))

(defun ycmd-close ()
  "Shutdown any running ycmd server.

This does nothing if no server is running."
  (interactive)
  (when (ycmd-running?)
    (ycmd--stop-server))
  (ycmd--global-teardown)
  (ycmd--kill-timer ycmd--keepalive-timer))

(defun ycmd--stop-server ()
  "Stop the ycmd server process.

Call `interrupt-process' for the ycmd server and wait for the
ycmd server to stop.  If the ycmd server is still running after a
timeout specified by `ycmd-delete-process-delay', then kill the
process with `delete-process'."
  (condition-case nil
      (let ((start-time (float-time)))
        (interrupt-process ycmd--server-process-name)
        (while (and (ycmd-running?)
                    (> ycmd-delete-process-delay
                       (- (float-time) start-time)))
          (sit-for 0.05))
        (delete-process ycmd--server-process-name))
    (error nil)))

(defun ycmd-running? ()
  "Return t if a ycmd server is already running."
  (--when-let (get-process ycmd--server-process-name)
    (and (processp it) (process-live-p it) t)))

(defun ycmd--keepalive ()
  "Sends an unspecified message to the server.

This is simply for keepalive functionality."
  (ycmd--request "/healthy" '() :type "GET"))

(defun ycmd-load-conf-file (filename)
  "Tell the ycmd server to load the configuration file FILENAME."
  (interactive
   (list
    (read-file-name "Filename: ")))
  (let ((filename (expand-file-name filename)))
    (ycmd--request
     "/load_extra_conf_file"
     `(("filepath" . ,filename)))))

(defun ycmd-display-completions ()
  "Get completions at the current point and display them in a buffer.

This is really a utility/debugging function for developers, but
it might be interesting for some users."
  (interactive)
  (deferred:$
    (ycmd-get-completions)
    (deferred:nextc it
      (lambda (completions)
        (pop-to-buffer "*ycmd-completions*")
        (erase-buffer)
        (insert (pp-to-string completions))))))

(defun ycmd-toggle-force-semantic-completion ()
  "Toggle whether to use always semantic completion.

Returns the new value of `ycmd-force-semantic-completion'."
  (interactive)
  (let ((force (not ycmd-force-semantic-completion)))
    (message "ycmd: force semantic completion %s."
             (if force "enabled" "disabled"))
    (setq ycmd-force-semantic-completion force)))

(defun ycmd--string-list-p (obj)
  "Return t if OBJ is a list of strings."
  (and (listp obj) (-all? #'stringp obj)))

(defun ycmd--locate-default-tags-file (buffer)
  "Look up directory hierarchy for first found default tags file for BUFFER."
  (-when-let* ((file (buffer-file-name buffer))
               (dir (and file
                         (locate-dominating-file
                          file ycmd-default-tags-file-name))))
    (expand-file-name ycmd-default-tags-file-name dir)))

(defun ycmd--get-tag-files (buffer)
  "Get tag files list for current BUFFER or nil."
  (--when-let (cond ((eq ycmd-tag-files 'auto)
                     (ycmd--locate-default-tags-file buffer))
                    ((or (stringp ycmd-tag-files)
                         (ycmd--string-list-p ycmd-tag-files))
                     ycmd-tag-files))
    (unless (listp it)
      (setq it (list it)))
    (mapcar 'expand-file-name it)))

(defun ycmd--get-keywords (buffer)
  "Get syntax keywords for BUFFER."
  (with-current-buffer buffer
    (let ((mode major-mode))
      (unless (memq mode ycmd--mode-keywords-loaded)
        (--when-let (and (functionp ycmd-get-keywords-function)
                         (funcall ycmd-get-keywords-function mode))
          (when (ycmd--string-list-p it)
            (add-to-list 'ycmd--mode-keywords-loaded mode)
            it))))))

(defun ycmd--get-keywords-from-alist (mode)
  "Get keywords from `ycmd-keywords-alist' for MODE."
  (let ((symbols (cdr (assq mode ycmd-keywords-alist))))
    (if (consp symbols)
        symbols
      (cdr (assq symbols ycmd-keywords-alist)))))

(defun ycmd-get-completions (&optional sync)
  "Get completions in current buffer from the ycmd server.

Returns a deferred object which yields the HTTP message
content.  If completions are available, the structure looks like
this:

   ((completion_start_column . 6)
    (completions .
                 [((kind . \"FUNCTION\")
                   (extra_menu_info . \"long double\")
                   (detailed_info . \"long double acoshl( long double )\n\")
                   (insertion_text . \"acoshl\")
                   (menu_text . \"acoshl( long double )\"))
                   . . .]))

If ycmd can't do completion because it's busy parsing, the
structure looks like this:

  ((message . \"Still parsing file, no completions yet.\")
   (traceback . \"long traceback string\")
   (exception
    (TYPE . \"RuntimeError\")))

To see what the returned structure looks like, you can use
`ycmd-display-completions'.

If SYNC is non-nil the function does not return a deferred object
and blocks until the request has finished."
  (when ycmd-mode
    (let* ((buffer (current-buffer))
           (extra-content (and ycmd-force-semantic-completion
                               'force-semantic))
           (content (ycmd--standard-content-with-extras
                     buffer extra-content)))
      (ycmd--request
       "/completions"
       content
       :parser 'json-read
       :sync sync))))

(defun ycmd--handle-exception (results)
  "Handle exception in completion RESULTS.

This function handles 'UnknownExtraConf' exceptions or exceptions
handled by a DEFAULT-HANDLER, which must be a function that takes
a results vector as argument."
  (let* ((exception (assoc-default 'exception results))
         (exception-type (assoc-default 'TYPE exception)))
    (pcase exception-type
      ("UnknownExtraConf"
       (ycmd--handle-extra-conf-exception results))
      ((or "ValueError" "RuntimeError")
       (ycmd--handle-error-exception results)))))

(defun ycmd--send-request (type success-handler)
  "Send a request of TYPE to the `ycmd' server.

SUCCESS-HANDLER is called when for a successful response."
  (when ycmd-mode
    (if (ycmd-parsing-in-progress-p)
        (message "Can't send \"%s\" request while parsing is in progress!"
                 type)
      (deferred:$
        (ycmd--send-completer-command-request type)
        (deferred:nextc it
          (lambda (result)
            (when result
              (if (and (not (vectorp result))
                       (assoc-default 'exception result))
                  (ycmd--handle-exception result)
                (when success-handler
                  (funcall success-handler result))))))))))

(defun ycmd--send-completer-command-request (type)
  "Send Go To request of TYPE to BUFFER at POS."
  (let* ((buffer (current-buffer))
         (content (cons (list "command_arguments" type)
                        (ycmd--standard-content buffer))))
    (ycmd--request
     "/run_completer_command"
     content
     :parser 'json-read)))

(defun ycmd-goto ()
  "Go to the definition or declaration of the symbol at current position."
  (interactive)
  (ycmd--goto "GoTo"))

(defun ycmd-goto-declaration ()
  "Go to the declaration of the symbol at the current position."
  (interactive)
  (ycmd--goto "GoToDeclaration"))

(defun ycmd-goto-definition ()
  "Go to the definition of the symbol at the current position."
  (interactive)
  (ycmd--goto "GoToDefinition"))

(defun ycmd-goto-implementation ()
  "Go to the implementation of the symbol at the current position."
  (interactive)
  (ycmd--goto "GoToImplementation"))

(defun ycmd-goto-include ()
  "Go to the include of the symbol at the current position."
  (interactive)
  (ycmd--goto "GoToInclude"))

(defun ycmd-goto-imprecise ()
  "Fast implementation of Go To at the cost of precision.
Useful in case compile-time is considerable."
  (interactive)
  (ycmd--goto "GoToImprecise"))

(defun ycmd-goto-references ()
  "Get references."
  (interactive)
  (ycmd--goto "GoToReferences"))

(defun ycmd--save-marker ()
  "Save marker."
  (push-mark)
  (if (fboundp 'xref-push-marker-stack)
      (xref-push-marker-stack)
    (with-no-warnings
      (ring-insert find-tag-marker-ring (point-marker)))))

(defun ycmd--handle-goto-success (result)
  "Handle a successfull GoTo response for RESULT."
  (let* ((is-vector (vectorp result))
         (num-items (if is-vector (length result) 1)))
    (ycmd--save-marker)
    (when is-vector
      (setq result (append result nil)))
    (if (eq 1 num-items)
        (ycmd--goto-location result 'find-file)
      (ycmd--view result major-mode))))

(defun ycmd--goto (type)
  "Implementation of GoTo according to the request TYPE."
  (ycmd--send-request type 'ycmd--handle-goto-success))

(defun ycmd--goto-location (location find-function)
  "Move cursor to LOCATION with FIND-FUNCTION.

LOCATION is a structure as returned from e.g. the various GoTo
commands."
  (--when-let (assoc-default 'filepath location)
    (funcall find-function it)
    (goto-char (ycmd--col-line-to-position
                (assoc-default 'column_num location)
                (assoc-default 'line_num location)))))

(defun ycmd--goto-line (line)
  "Go to LINE."
  (goto-char (point-min))
  (forward-line (1- line)))

(defun ycmd--col-line-to-position (col line &optional buffer)
  "Convert COL and LINE into a position in the current buffer.

COL and LINE are expected to be as returned from ycmd, e.g. from
notify-file-ready.  Apparently COL can be 0 sometimes, in which
case this function returns 0.
Use BUFFER if non-nil or `current-buffer'."
  (let ((buff (or buffer (current-buffer))))
    (if (= col 0)
        0
      (with-current-buffer buff
        (ycmd--goto-line line)
        (forward-char (- col 1))
        (point)))))

(defun ycmd-clear-compilation-flag-cache ()
  "Clear the compilation flags cache."
  (interactive)
  (ycmd--send-request "ClearCompilationFlagCache" nil))

(cl-defun ycmd--fontify-code (code &optional (mode major-mode))
  "Fontify CODE."
  (cl-check-type mode function)
  (if (not (stringp code))
      code
    (with-temp-buffer
      (delay-mode-hooks (funcall mode))
      (setq font-lock-mode t)
      (funcall font-lock-function font-lock-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert code)
        (font-lock-default-fontify-region
         (point-min) (point-max) nil))
      (buffer-string))))

(defun ycmd--handle-get-parent-or-type-success (result)
  "Handle a successful GetParent or GetType resonse for RESULT."
  (-when-let (msg (assoc-default 'message result))
    (message "%s" (pcase msg
                    ((or `"Unknown semantic parent"
                         `"Unknown type"
                         `"Internal error: cursor not valid"
                         `"Internal error: no translation unit") msg)
                    (_ (ycmd--fontify-code msg))))))

(defun ycmd-get-parent ()
  "Get semantic parent for symbol at point."
  (interactive)
  (ycmd--send-request
   "GetParent" 'ycmd--handle-get-parent-or-type-success))

(defun ycmd-get-type ()
  "Get type for symbol at point."
  (interactive)
  (ycmd--send-request
   "GetType" 'ycmd--handle-get-parent-or-type-success))

(defun ycmd--replace-chunk (start end replacement-text line-delta char-delta buffer)
  "Replace text between START and END with REPLACEMENT-TEXT.

LINE-DELTA and CHAR-DELTA are offset from former replacements on
the current line.  BUFFER is the current working buffer."
  (let* ((start-line (+ (car start) line-delta))
         (end-line (+ (car end) line-delta))
         (source-line-count (1+ (- end-line start-line)))
         (start-column (+ (cdr start) char-delta))
         (end-column (cdr end))
         (replacement-lines (s-split "\n" replacement-text))
         (replacement-lines-count (length replacement-lines))
         (new-line-delta (- replacement-lines-count source-line-count))
         new-char-delta)
    (when (= source-line-count 1)
      (setq end-column (+ end-column char-delta)))
    (setq new-char-delta (- (length (car (last replacement-lines)))
                            (- end-column start-column)))
    (when (> replacement-lines-count 1)
      (setq new-char-delta (- new-char-delta start-column)))
    (save-excursion
      (with-current-buffer buffer
        (delete-region
         (ycmd--col-line-to-position start-column start-line buffer)
         (ycmd--col-line-to-position end-column end-line buffer))
        (insert replacement-text)
        (cons new-line-delta new-char-delta)))))

(defun ycmd--get-chunk-line-and-column (chunk start-or-end)
  "Get a cons cell with line and column of CHUNK.

START-OR-END specifies whether to get the range start or end."
  (let* ((range (assoc-default 'range chunk))
         (pos (assoc-default start-or-end range))
         (line-num (assoc-default 'line_num pos))
         (column-num (assoc-default 'column_num pos)))
    (cons line-num column-num)))

(defun ycmd--chunk-< (c1 c2)
  "Return t if C1 should go before C2."
  (let* ((start-c1 (ycmd--get-chunk-line-and-column c1 'start))
         (line-num-1 (car start-c1))
         (column-num-1 (cdr start-c1))
         (start-c2 (ycmd--get-chunk-line-and-column c2 'start))
         (line-num-2 (car start-c2))
         (column-num-2 (cdr start-c2)))
    (or (< line-num-1 line-num-2)
        (and (= line-num-1 line-num-2)
             (< column-num-1 column-num-2)))))

(defun ycmd--replace-chunk-list (chunks &optional buffer)
  "Replace list of CHUNKS.

If BUFFER is spacified use it as working buffer, else use current
buffer."
  (let ((chunks-sorted (sort chunks 'ycmd--chunk-<))
        (buf (or buffer (current-buffer)))
        (last-line -1)
        (line-delta 0)
        (char-delta 0))
    (dolist (c chunks-sorted)
      (-when-let* ((chunk-start (ycmd--get-chunk-line-and-column c 'start))
                   (chunk-end (ycmd--get-chunk-line-and-column c 'end))
                   (replacement-text (assoc-default 'replacement_text c)))
        (unless (= (car chunk-start) last-line)
          (setq last-line (car chunk-end))
          (setq char-delta 0))
        (let ((new-deltas (ycmd--replace-chunk
                           chunk-start chunk-end replacement-text
                           line-delta char-delta buf)))
          (setq line-delta (+ line-delta (car new-deltas)))
          (setq char-delta (+ char-delta (cdr new-deltas))))))))

(defun ycmd--handle-fixit-success (result)
  "Handle a successful FixIt response for RESULT."
  (-if-let* ((fixits (assoc-default 'fixits result))
             (fixits (append fixits nil)))
      (let ((use-dialog-box nil))
        (when (or (not ycmd-confirm-fixit)
                  (y-or-n-p "Apply FixIts on current line? "))
          (dolist (fixit fixits)
            (-when-let (chunks (assoc-default 'chunks fixit))
              (ycmd--replace-chunk-list (append chunks nil))))))
    (message "No FixIts available")))

(defun ycmd-fixit()
  "Get FixIts for current line."
  (interactive)
  (ycmd--send-request "FixIt" 'ycmd--handle-fixit-success))

(defun ycmd-show-documentation (&optional arg)
  "Show documentation for current point in buffer.

If optional ARG is non-nil do not reparse buffer before getting
the documentation."
  (interactive "P")
  (ycmd--send-request
   (if arg "GetDocQuick" "GetDoc")
   'ycmd--handle-get-doc-success))

(defun ycmd--handle-get-doc-success (result)
  "Handle successful GetDoc response for RESULT."
  (let ((documentation (assoc-default 'detailed_info result)))
    (if (not (s-blank? documentation))
        (with-help-window (get-buffer-create " *ycmd-documentation*")
          (with-current-buffer standard-output
            (insert documentation)))
      (message "No documentation available for current context"))))

(defmacro ycmd--with-view-buffer (&rest body)
  "Create view buffer and execute BODY in it."
  `(let ((buf (get-buffer-create "*ycmd-locations*")))
     (with-current-buffer buf
       (setq buffer-read-only nil)
       (erase-buffer)
       ,@body
       (goto-char (point-min))
       (ycmd-view-mode)
       buf)))

(defun ycmd--view (result mode)
  "Select a `ycmd-view-mode' buffer and display RESULT.
MODE is a major mode for fontifaction."
  (pop-to-buffer
   (ycmd--with-view-buffer
    (->>
     (--group-by (cdr (assoc 'filepath it)) result)
     (--map (ycmd--view-insert-location it mode))))))

(define-button-type 'ycmd--location-button
  'action #'ycmd--view-jump
  'face nil)

(defun ycmd--view-jump (button)
  "Jump to BUTTON's location in current window."
  (let ((location (button-get button 'location)))
    (ycmd--goto-location location 'find-file)))

(defun ycmd--view-jump-other-window (button)
  "Jump to BUTTON's location in other window."
  (let ((location (button-get button 'location)))
    (ycmd--goto-location location 'find-file-other-window)))

(defun ycmd--view-insert-button (name location)
  "Insert a view button with NAME and LOCATION."
  (insert-text-button
   name
   'type 'ycmd--location-button
   'location location))

(defun ycmd--view-insert-location (location mode)
  "Insert LOCATION into buffer and fontify according MODE."
  (let* ((max-line-num (cdr (assoc 'line_num
                                   (-max-by
                                    (lambda (a b)
                                      (let ((a (cdr (assoc 'line_num a)))
                                            (b (cdr (assoc 'line_num b))))
                                        (when (and (numberp a) (numberp b))
                                          (> a b))))
                                    (cdr location)))))
         (max-line-num-width (and max-line-num
                                  (length (format "%d" max-line-num))))
         (line-num-format (and max-line-num-width
                               (format "%%%dd:" max-line-num-width))))
    (insert (propertize (concat (car location) "\n") 'face 'bold))
    (--map
     (progn
       (when line-num-format
         (insert (format line-num-format (cdr (assoc 'line_num it)))))
       (insert "    ")
       (ycmd--view-insert-button
        (ycmd--fontify-code (cdr (assoc 'description it)) mode)
        it)
       (insert "\n"))
     (cdr location))))

(defvar ycmd-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") 'next-error-no-select)
    (define-key map (kbd "p") 'previous-error-no-select)
    (define-key map (kbd "q") 'quit-window)
    map))

(define-derived-mode ycmd-view-mode special-mode "ycmd-view"
  "Major mode for locations view and navigation for `ycmd-mode'.

\\{ycmd-view-mode-map}"
  (setq next-error-function #'ycmd--next-location))

(defun ycmd--next-location (num _reset)
  "Navigate to the next location in the view buffer.
NUM is the number of locations to move forward.  If RESET is
non-nil got to the beginning of buffer before locations
navigation."
  (forward-button num)
  (ycmd--view-jump-other-window (button-at (point))))

(define-button-type 'ycmd--error-button
  'face '(error bold underline)
  'button 't)

(define-button-type 'ycmd--warning-button
  'face '(warning bold underline)
  'button 't)

(defun ycmd--make-button (start end type message)
  "Make a button from START to END of TYPE in the current buffer.

When clicked, this will popup MESSAGE."
  (make-text-button
   start end
   'type type
   'action (lambda (_) (popup-tip message))))

(defconst ycmd--file-ready-buttons
  '(("ERROR" . ycmd--error-button)
    ("WARNING" . ycmd--warning-button))
  "A mapping from parse 'kind' to button types.")

(defun ycmd--line-start-position (line)
  "Find position at the start of LINE."
  (save-excursion
    (ycmd--goto-line line)
    (beginning-of-line)
    (point)))

(defun ycmd--line-end-position (line)
  "Find position at the end of LINE."
  (save-excursion
    (ycmd--goto-line line)
    (end-of-line)
    (point)))

(defmacro ycmd--with-destructured-parse-result (result body)
  "Destructure parse RESULT and evaluate BODY."
  (declare (indent 1) (debug t))
  `(let* ((location_extent  (assoc-default 'location_extent ,result))
          (le_end           (assoc-default 'end location_extent))
          (end-line-num     (assoc-default 'line_num le_end))
          (end-column-num   (assoc-default 'column_num le_end))
          (end-filepath     (assoc-default 'filepath le_end))
          (le_start         (assoc-default 'start location_extent))
          (start-line-num   (assoc-default 'line_num le_start))
          (start-column-num (assoc-default 'column_num le_start))
          (start-filepath   (assoc-default 'filepath le_start))
          (location         (assoc-default 'location ,result))
          (line-num         (assoc-default 'line_num location))
          (column-num       (assoc-default 'column_num location))
          (filepath         (assoc-default 'filepath location))
          (kind             (assoc-default 'kind ,result))
          (text             (assoc-default 'text ,result))
          (ranges           (assoc-default 'ranges ,result))
          (fixit-available  (assoc-default 'fixit_available ,result)))
     ,body))

(defun ycmd--decorate-single-parse-result (r)
  "Decorates a buffer based on the contents of a single parse result struct R.

This is a fairly crude form of decoration, but it does give
reasonable visual feedback on the problems found by ycmd."
  (ycmd--with-destructured-parse-result r
    (--when-let (find-buffer-visiting filepath)
      (with-current-buffer it
        (let* ((start-pos (ycmd--line-start-position line-num))
               (end-pos (ycmd--line-end-position line-num))
               (btype (assoc-default kind ycmd--file-ready-buttons)))
          (when btype
            (with-silent-modifications
              (ycmd--make-button
               start-pos end-pos
               btype
               (concat kind ": " text)))))))))

(defun ycmd-decorate-with-parse-results (results)
  "Decorates a buffer using the RESULTS of a file-ready parse list.

This is suitable as an entry in `ycmd-file-parse-result-hook'."
  (with-silent-modifications
    (set-text-properties (point-min) (point-max) nil))
  (mapc 'ycmd--decorate-single-parse-result results)
  results)

(defun ycmd--display-single-file-parse-result (result)
  "Insert a single file parse RESULT."
  (ycmd--with-destructured-parse-result result
    (insert (format "%s:%s - %s - %s\n" filepath line-num kind text))))

(defun ycmd-display-file-parse-results (results)
  "Display parse RESULTS in a buffer."
  (let ((buffer "*ycmd-file-parse-results*"))
    (get-buffer-create buffer)
    (with-current-buffer buffer
      (erase-buffer)
      (mapc 'ycmd--display-single-file-parse-result results))
    (display-buffer buffer)))

(defun ycmd-parse-buffer ()
  "Parse buffer."
  (interactive)
  (ycmd--report-status 'unparsed)
  (ycmd--conditional-parse))

(defun ycmd--handle-extra-conf-exception (result)
  "Handle an exception of type `UnknownExtraConf' in RESULT.

Handle configuration file according the value of
`ycmd-extra-conf-handler'."
  (let* ((exception (assoc-default 'exception result))
         (conf-file (assoc-default 'extra_conf_file exception))
         location)
    (if (not conf-file)
        (warn "No extra_conf_file included in UnknownExtraConf exception. \
Consider reporting this.")
      (if (and (not (eq ycmd-extra-conf-handler 'ignore))
               (y-or-n-p (format "Load YCMD extra conf %s? " conf-file)))
          (setq location "/load_extra_conf_file")
        (setq location "/ignore_extra_conf_file"))
      (deferred:sync!
        (ycmd--request location `((filepath . ,conf-file))))
      (ycmd--report-status 'unparsed)
      (ycmd-notify-file-ready-to-parse))))

(defun ycmd--handle-error-exception (results)
  "Handle exception and print message from RESULTS."
  (let* ((msg (assoc-default 'message results))
         (is-error (pcase msg
                     ((or "Still no compile flags, no completions yet."
                          "File is invalid."
                          "No completions found; errors in the file?"
                          (pred (string-prefix-p "Gocode binary not found."))
                          "Gocode binary not found."
                          "Gocode returned invalid JSON response."
                          (pred (string-prefix-p "Gocode panicked"))
                          "Received invalid HMAC for response!")
                      t))))
    (when is-error
      (ycmd--report-status 'errored))
    (message "%s" (concat (when is-error "ERROR: ")
                          (if msg msg "Unknown exception.")))))

(defun ycmd--handle-notify-response (results)
  "If RESULTS is a vector or nil, the response is an acual parse result.
Otherwise the response is probably an exception."
  (if (or (not results)
          (vectorp results))
      (progn
        (ycmd--report-status 'parsed)
        (run-hook-with-args 'ycmd-file-parse-result-hook results))
    (when (assoc 'exception results)
      (ycmd--handle-exception results))))

(defun ycmd-notify-file-ready-to-parse ()
  "Send a notification to ycmd that the buffer is ready to be parsed.

Only one active notification is allowed per buffer, and this
function enforces that constraint.

The results of the notification are passed to all of the
functions in `ycmd-file-parse-result-hook'."
  (when (and ycmd-mode (not (ycmd-parsing-in-progress-p)))
    (let* ((buff (current-buffer))
           (extra-content (append (when ycmd-tag-files
                                    (list 'tags))
                                  (when ycmd-seed-identifiers-with-keywords
                                    (list 'syntax-keywords))))
           (content (cons '("event_name" . "FileReadyToParse")
                          (ycmd--standard-content-with-extras
                           buff extra-content))))
      (deferred:$
        ;; try
        (deferred:$
          ;; Record that the buffer is being parsed
          (ycmd--report-status 'parsing)

          ;; Make the request.
          (ycmd--request "/event_notification"
                         content
                         :parser 'json-read)

          (deferred:nextc it
            (lambda (results)
              (with-current-buffer buff
                (ycmd--handle-notify-response results)))))

        ;; catch
        (deferred:error it
          (lambda (err)
            (message "Error sending notification request: %s" err)
            (ycmd--report-status 'errored)))))))

(defun ycmd-display-raw-file-parse-results ()
  "Request file-parse results and display them in a buffer in raw form.

This is primarily a debug/developer tool."
  (interactive)
  (let ((ycmd-file-parse-result-hook
         `(lambda (content)
            (pop-to-buffer "*ycmd-file-ready*")
            (erase-buffer)
            (insert (pp-to-string content)))))
    (deferred:sync!
      (ycmd-notify-file-ready-to-parse))))

(defun ycmd-major-mode-to-file-types (mode)
  "Map a major mode MODE to a list of file-types suitable for ycmd.

If there is no established mapping, return nil."
  (cdr (assoc mode ycmd-file-type-map)))

(defun ycmd--start-keepalive-timer ()
  "Kill any existing keepalive timer and start a new one."
  (ycmd--kill-timer ycmd--keepalive-timer)
  (setq ycmd--keepalive-timer
        (run-with-timer
         ycmd-keepalive-period
         ycmd-keepalive-period
         #'ycmd--keepalive)))

(defun ycmd--generate-hmac-secret ()
  "Generate a new, random 16-byte HMAC secret key."
  (let ((result '()))
    (dotimes (_ 16 result)
      (setq result (cons (byte-to-string (random 256)) result)))
    (apply 'concat result)))

(defun ycmd--json-encode (obj)
  "Encode a json object OBJ.
A version of json-encode that uses {} instead of null for nil values.
This produces output for empty alists that ycmd expects."
  (cl-flet ((json-encode-keyword (k) (cond ((eq k t)          "true")
                                           ((eq k json-false) "false")
                                           ((eq k json-null)  "{}"))))
    (json-encode obj)))

;; This defines 'ycmd--hmac-function which we use to combine an HMAC
;; key and message contents.
(defun ycmd--secure-hash (x)
  "Generate secure sha256 hash of X."
  (secure-hash 'sha256 x nil nil 1))
(define-hmac-function ycmd--hmac-function
  ycmd--secure-hash 64 64)

(defun ycmd--options-contents (hmac-secret)
  "Return a struct with ycmd options and the HMAC-SECRET applied.
The struct can be json encoded into a file to create a ycmd
options file.

When we start a new ycmd server, it needs an options file.  It
reads this file and then deletes it since it contains a secret
key.  So we need to generate a new options file for each ycmd
instance.  This function effectively produces the contents of that
file."
  (let ((hmac-secret (base64-encode-string hmac-secret))
        (global-config (or ycmd-global-config ""))
        (extra-conf-whitelist (or ycmd-extra-conf-whitelist []))
        (confirm-extra-conf (if (eq ycmd-extra-conf-handler 'load) 0 1))
        (gocode-binary-path (or ycmd-gocode-binary-path ""))
        (godef-binary-path (or ycmd-godef-binary-path ""))
        (rust-src-path (or ycmd-rust-src-path ""))
        (racerd-binary-path (or ycmd-racerd-binary-path ""))
        (python-binary-path (or ycmd-python-binary-path "")))
    `((filepath_completion_use_working_dir . 0)
      (auto_trigger . 1)
      (min_num_of_chars_for_completion . ,ycmd-min-num-chars-for-completion)
      (min_num_identifier_candidate_chars . 0)
      (semantic_triggers . ())
      (filetype_specific_completion_to_disable (gitcommit . 1))
      (collect_identifiers_from_comments_and_strings . 0)
      (max_num_identifier_candidates . ,ycmd-max-num-identifier-candidates)
      (extra_conf_globlist . ,extra-conf-whitelist)
      (global_ycm_extra_conf . ,global-config)
      (confirm_extra_conf . ,confirm-extra-conf)
      (max_diagnostics_to_display . 30)
      (auto_start_csharp_server . 1)
      (auto_stop_csharp_server . 1)
      (use_ultisnips_completer . 1)
      (csharp_server_port . 0)
      (hmac_secret . ,hmac-secret)
      (server_keep_logfiles . 1)
      (gocode_binary_path . ,gocode-binary-path)
      (godef_binary_path . ,godef-binary-path)
      (rust_src_path . ,rust-src-path)
      (racerd_binary_path . ,racerd-binary-path)
      (python_binary_path . ,python-binary-path))))

(defun ycmd--create-options-file (hmac-secret)
  "Create a new options file for a ycmd server with HMAC-SECRET.

This creates a new tempfile and fills it with options.  Returns
the name of the newly created file."
  (let ((options-file (make-temp-file "ycmd-options"))
        (options (ycmd--options-contents hmac-secret)))
    (with-temp-file options-file
      (insert (ycmd--json-encode options)))
    options-file))

(defun ycmd--start-server (hmac-secret)
  "Start a new server using HMAC-SECRET as its hmac secret."
  (let ((proc-buff (get-buffer-create ycmd--server-buffer-name)))
    (with-current-buffer proc-buff
      (buffer-disable-undo proc-buff)
      (erase-buffer)

      (let* ((options-file (ycmd--create-options-file hmac-secret))
             (server-command ycmd-server-command)
             (args (apply 'list (concat "--options_file=" options-file)
                          ycmd-server-args))
             (server-program+args (append server-command args))
             (proc (apply #'start-process ycmd--server-process-name proc-buff
                          server-program+args))
             (cont t)
             (start-time (float-time)))
        (while cont
          (set-process-query-on-exit-flag proc nil)
          (accept-process-output proc 0 100 t)
          (let ((proc-output (with-current-buffer proc-buff
                               (buffer-string))))
            (cond
             ((string-match "^serving on http://.*:\\\([0-9]+\\\)$" proc-output)
              (progn
                (set-variable 'ycmd--server-actual-port
                              (string-to-number (match-string 1 proc-output)))
                (setq cont nil)
                (ycmd--with-all-ycmd-buffers (ycmd--report-status 'unparsed))))
             (t
              ;; timeout after specified period
              (when (< ycmd-startup-timeout (- (float-time) start-time))
                (ycmd--with-all-ycmd-buffers (ycmd--report-status 'errored))
                (when (ycmd-running?) (ycmd-close))
                (error "ERROR: Ycmd server timeout"))))))))))

(defun ycmd--column-in-bytes ()
  "Calculate column offset in bytes for the current position and buffer."
  (- (position-bytes (point))
     (position-bytes (line-beginning-position))))

(defun ycmd--encode-string (s)
  "Encode string S."
  (if (version-list-< (version-to-list emacs-version) '(25))
      s
    (encode-coding-string s 'utf-8 t)))

(defun ycmd--standard-content (&optional buffer)
  "Generate the 'standard' content for ycmd posts.

This extracts a bunch of information from BUFFER.  If BUFFER is
nil, this uses the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (let* ((column-num (+ 1 (ycmd--column-in-bytes)))
           (line-num (line-number-at-pos (point)))
           (full-path (ycmd--encode-string (or (buffer-file-name) "")))
           (file-contents (ycmd--encode-string
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
           (file-types (or (ycmd-major-mode-to-file-types major-mode)
                           '("generic"))))
      `(("file_data" .
         ((,full-path . (("contents" . ,file-contents)
                         ("filetypes" . ,file-types)))))
        ("filepath" . ,full-path)
        ("line_num" . ,line-num)
        ("column_num" . ,column-num)))))

(defun ycmd--standard-content-with-extras (buffer &optional extras)
  "Generate 'standard' content for BUFFER with EXTRAS."
  (let ((standard-content (ycmd--standard-content buffer)))
    (unless (listp extras)
      (setq extras (list extras)))
    (dolist (extra extras standard-content)
      (--when-let (pcase extra
                    (`force-semantic
                     (cons "force_semantic" t))
                    (`tags
                     (--when-let (ycmd--get-tag-files buffer)
                       (cons "tag_files" it)))
                    (`syntax-keywords
                     (--when-let (ycmd--get-keywords buffer)
                       (cons "syntax_keywords" it))))
        (push it standard-content)))))


(defvar ycmd--log-enabled nil
  "If non-nil, http content will be logged.
This is useful for debugging.")

(defun ycmd--log-content (header content)
  "Insert log with HEADER and CONTENT in a buffer."
  (when ycmd--log-enabled
    (let ((buffer (get-buffer-create "*ycmd-content-log*")))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-max))
          (insert (format "\n%s\n\n" header))
          (insert (pp-to-string content)))))))

(defun ycmd-show-debug-info ()
  "Show debug information."
  (interactive)
  (when ycmd-mode
    (let ((buffer (current-buffer)))

      (deferred:$
        (let ((content (ycmd--standard-content buffer)))
          (ycmd--request
           "/debug_info"
           content
           :parser 'json-read))

        (deferred:nextc it
          (lambda (res)
            (when res
              (with-help-window (get-buffer-create " *ycmd-debug-info*")
                (with-current-buffer standard-output
                  (princ "ycmd debug information for buffer ")
                  (insert (propertize (buffer-name buffer) 'face 'bold))
                  (princ " in ")
                  (let ((mode (buffer-local-value 'major-mode buffer)))
                    (insert-button (symbol-name mode)
                                   'type 'help-function
                                   'help-args (list mode)))
                  (princ ":\n\n")
                  (insert res)
                  (princ "\n\n")
                  (insert (format "Server running at: %s:%d"
                                  ycmd-host ycmd--server-actual-port)))))))))))

(defun ycmd--get-request-hmac (method path body)
  "Generate HMAC for request from METHOD, PATH and BODY."
  (ycmd--hmac-function
   (mapconcat (lambda (val)
                (ycmd--hmac-function
                 (ycmd--encode-string val) ycmd--hmac-secret))
              `(,method ,path ,(or body "")) "")
   ycmd--hmac-secret))

(cl-defun ycmd--request (location
                         content
                         &key
                         (parser 'buffer-string)
                         (type "POST")
                         (sync nil))
  "Send an asynchronous HTTP request to the ycmd server.

This starts the server if necessary.

Returns a deferred object which resolves to the content of the
response message.

LOCATION specifies the location portion of the URL. For example,
if LOCATION is '/feed_llama', the request URL is
'http://host:port/feed_llama'.

CONTENT will be JSON-encoded and sent over at the content of the
HTTP message.

PARSER specifies the function that will be used to parse the
response to the message. Typical values are buffer-string and
json-read. This function will be passed an the completely
unmodified contents of the response (i.e. not JSON-decoded or
anything like that.)
"
  (unless (ycmd-running?) (ycmd-open))

  (let* ((url-show-status (not ycmd-hide-url-status))
         (url-proxy-services (unless ycmd-bypass-url-proxy-services
                               url-proxy-services))
         (ycmd-request-backend 'url-retrieve)
         (content (json-encode content))
         (hmac (ycmd--get-request-hmac type location content))
         (encoded-hmac (base64-encode-string hmac 't))
         (url (format "http://%s:%s%s"
                      ycmd-host ycmd--server-actual-port location))
         (headers `(("Content-Type" . "application/json")
                    ("X-Ycm-Hmac" . ,encoded-hmac))))
    (ycmd--log-content "HTTP REQUEST CONTENT" content)

    (if sync
        (let (result)
          (ycmd-request
           url :headers headers :parser parser :data content :type type
           :sync t
           :success
           (cl-function
            (lambda (&key data &allow-other-keys)
              (ycmd--log-content "HTTP RESPONSE CONTENT" data)
              (setq result data))))
          result)
      (deferred:$
        (ycmd-request-deferred
         url :headers headers :parser parser :data content :type type)
        (deferred:nextc it
          (lambda (req)
            (let ((content (ycmd-request-response-data req)))
              (ycmd--log-content "HTTP RESPONSE CONTENT" content)
              content)))))))

(provide 'ycmd)

;;; ycmd.el ends here

;; Local Variables:
;; indent-tabs-mode: nil
;; byte-compile-warnings: (not mapcar)
;; End:
