;;; -*- Gerbil -*-
;;; (C) vyzo
;;; actor message primitives and macros
package: std/actor

(import :gerbil/gambit/threads
        :gerbil/gambit/os
        (only-in :std/event !)
        :std/error)
(export
  (struct-out message proxy)
  (struct-out actor-error)
  actor-error:::init!
  -> send send-message send-message/timeout
  << <-
  !)

;; ~~lib/_gambit#.scm
(extern namespace: #f
  macro-absent-obj
  macro-mailbox-mutex
  macro-mailbox-condvar
  macro-mailbox-cursor
  macro-mailbox-cursor-set!
  macro-mailbox-fifo
  macro-fifo-next
  macro-fifo-next-set!
  macro-fifo-elem
  macro-fifo-tail-set!)

(defstruct (actor-error <error>) ()
  constructor: :init!)

(defmethod {:init! actor-error}
  (lambda (self where what . irritants)
    (struct-instance-init! self what irritants where)))

;;; structured messages
(defstruct message (e source dest options)
  final: #t)

(defstruct proxy (handler))

;;; send primitives
(def (send dest msg (check-dead? #f))
  (let lp ((dest dest))
    (cond
     ((thread? dest)
      (cond
       ((not check-dead?)
        (thread-send dest msg))
       ((thread-send/check dest msg))
       (else
        (raise (make-actor-error 'send "Cannot send message; dead thread" dest msg)))))
     ((proxy? dest)
      (lp (proxy-handler dest)))
     (else
      (lp (call-method ':actor dest))))))

(def (send-message dest value (options #f) (check-dead? (proxy? dest)))
  (send dest (make-message value (current-thread) dest options)
        check-dead?))

(def (send-message/timeout dest value timeo (check-dead? (proxy? dest)))
  (send dest (make-message value (current-thread) dest [timeout: timeo])
        check-dead?))

(extern thread-send/check)
(begin-foreign
  (namespace ("std/actor/message#" send thread-send/check))
  (define (thread-send/check thread msg)
    (declare (not interrupts-enabled))
    (macro-check-initialized-thread thread (send thread msg)
      (if (macro-thread-end-condvar thread)
        (##thread-send thread msg)
        #f))))

(defsyntax (-> stx)
  (syntax-case stx ()
    ((macro msg)
     (with-syntax ((dest (stx-identifier #'macro '@source)))
       #'(send-message dest msg)))
    ((macro msg timeout: timeo)
     (with-syntax ((dest (stx-identifier #'macro '@source)))
       #'(send-message/timeout dest msg)))))

;;; receive primitives
;; receive macros
;; <- matches a structured message, << raw matches the raw message
(begin-syntax
  (def (generate-receive stx generate-recv-e)
    (syntax-case stx ()
      ((_ clause ...)
       (with-syntax* (((values clauses events else-clause)
                       (parse-receive stx #'(clause ...)))
                      (loop (genident 'loop))
                      (recv-e (generate-recv-e stx clauses #'loop)))
         (cond
          ((and (null? events) (not else-clause))
           #'(let loop ()
               (let (next (thread-mailbox-next))
                 (recv-e next))))
          (else-clause
           (with-syntax (((else-body ...) else-clause))
             #'(let loop ()
                 (let (next (mailbox-next))
                   (if (eq? next mailbox-empty)
                     ((lambda () (thread-mailbox-rewind) else-body ...))
                     (recv-e next))))))
          (else
           (with-syntax (((evt-arg ...) events))
             #'(let ((values timeo K) (receive-timeout evt-arg ...))
                 (let loop ()
                   (let (next (thread-mailbox-next timeo mailbox-timeout))
                     (if (eq? next mailbox-timeout)
                       (begin
                         (thread-mailbox-rewind)
                         (K timeo))
                       (recv-e next))))))))))))

  (def (generate-receive-recv-raw stx clauses loop)
    (with-syntax ((((pat body ...) ...) clauses)
                  (loop loop))
      #'(lambda (msg)
          (match msg
            (pat (thread-mailbox-extract-and-rewind) body ...) ...
            (else (loop))))))

  (def (generate-receive-recv-msg stx clauses loop)
    (with-syntax* (((macro . body) stx)
                   (@message (stx-identifier #'macro '@message))
                   (@value   (stx-identifier #'macro '@value))
                   (@source  (stx-identifier #'macro '@source))
                   (@dest    (stx-identifier #'macro '@dest))
                   (@options (stx-identifier #'macro '@options))
                   (((pat body ...) ...) clauses)
                   (loop loop))
      #'(lambda (@message)
          (match @message
            ((message @value @source @dest @options)
             (match @value
               (pat (thread-mailbox-extract-and-rewind) body ...) ...
               (else (loop))))
            (else (loop))))))

  (def (parse-receive stx clauses)
    (let lp ((rest clauses) (clauses []) (events []) (else-e #f))
      (syntax-case rest ()
        ((hd . rest)
         (syntax-case #'hd (=> ! else)
           ((! evt => K)
            (lp #'rest clauses
                (cons* #'K #'evt events)
                else-e))
           ((! evt body ...)
            (lp #'rest clauses
                (cons* #'(lambda ($e) body ...) #'evt events)
                else-e))
           ((else body ...)
            (cond
             (else-e
              (raise-syntax-error #f "Bad syntax; duplicate else clause" stx #'hd))
             ((not (stx-null? #'rest))
              (raise-syntax-error #f "Bad syntax; else clause must be last" stx #'hd))
             ((not (null? events))
              (raise-syntax-error #f "Bad syntax; else clause incompatible with cuts" stx #'hd))
             (else
              (lp #'rest clauses events #'(body ...)))))
           ((pat body ...)
            (lp #'rest
                (cons #'(pat body ...) clauses)
                events else-e))))
        (()
         (values (reverse clauses) (reverse events) else-e))))))

(defsyntax (<< stx)
  (generate-receive stx generate-receive-recv-raw))

(defsyntax (<- stx)
  (generate-receive stx generate-receive-recv-msg))

(def (receive-timeout . args)
  (def now #f)
  (let lp ((rest args) (timeo (macro-absent-obj)) (deadline #f) (K void))
    (match rest
      ([evt k . rest]
       (cond
        ((not evt)
         (lp rest timeo deadline K))
        ((time? evt)
         (let (evt-deadline (time->seconds evt))
           (if (or (not deadline) (< evt-deadline deadline))
             (lp rest evt evt-deadline k)
             (lp rest timeo deadline K))))
        ((real? evt)
         (unless now
           (set! now (##current-time-point)))
         (let (evt-deadline (+ now evt))
           (if (or (not deadline) (< evt-deadline deadline))
             (lp rest (seconds->time evt-deadline) evt-deadline k)
             (lp rest timeo deadline K))))
        (else
         (error "Illegal event; expected time, real, or #f" evt))))
      (else
       (values timeo K)))))

(def mailbox-timeout '#(timeout))
(extern mailbox-empty mailbox-next)

(begin-foreign
  (namespace ("std/actor/message#" mailbox-empty mailbox-next))

  (define mailbox-empty '#(empty))

  (define (mailbox-next)
    (declare (not interrupts-enabled))
    (let* ((mb
            (##thread-mailbox-get! (macro-current-thread)))
           (cursor
            (macro-mailbox-cursor mb))
           (next
            (if cursor
              (macro-fifo-next cursor)
              (macro-mailbox-fifo mb)))
           (next2
            (macro-fifo-next next)))
      (if (##pair? next2)
        (let ((result (macro-fifo-elem next2)))
          (macro-mailbox-cursor-set! mb next)
          result)
        mailbox-empty))))
