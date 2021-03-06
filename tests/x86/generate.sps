#!/usr/bin/env scheme-script
;; -*- mode: scheme; coding: utf-8 -*- !#
;; Copyright © 2016, 2017 Göran Weinholt <goran@weinholt.se>

;; Permission is hereby granted, free of charge, to any person obtaining a
;; copy of this software and associated documentation files (the "Software"),
;; to deal in the Software without restriction, including without limitation
;; the rights to use, copy, modify, merge, publish, distribute, sublicense,
;; and/or sell copies of the Software, and to permit persons to whom the
;; Software is furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
;; THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;; DEALINGS IN THE SOFTWARE.
#!r6rs

;; Test case generator for Zabavno, based on some ideas from schjig.

(import (rnrs (6))
        (machine-code assembler x86)
        (machine-code disassembler x86-opcodes)
        (zabavno cpu x86)
        (zabavno tests x86 make-elf))

(define *IGNORE-UNDEFINED-FLAGS?* #t)

(define *TEST-MNEMONICS*
  '(aaa aad
    ;; aam
    aas adc add and
    ;; arpl bound
    bsf bsr bt bts btr btc
    ;; call
    cbw clc cld
    ;; cli
    ;; clts
    cmc cmp
    ;; cmps
    cwd daa das dec
    ;; div enter hlt idiv
    imul
    ;; in
    inc
    ;; ins int into iret jcc jcxz jmp
    lahf
    ;; lar lds les lss lfs lgs
    lea
    ;; leave lgdt lidt lldt lmsw lods loop loope/loopne lsl ltr
    mov
    ;; mov dr, cr; movs
    movsx movzx mul neg not or
    ;; out outs; pop/popa popf push pusha pushf
    rcl rcr
    ;; rep repe repne ret
    rol ror sahf salc sar shl shr sbb
    ;; scas
    seto setno setb setnb setz setnz setbe setnbe
    sets setns setp setnp setl setnl setle setnle
    ;; sgdt sidt sldt smsw
    shld shrd stc std
    ;; sti stos str
    sub test
    ;; verr verrw wait
    xchg
    ;; xlat
    xor))

;;; Randomness

(define (make-xorshift32 seed)
  ;; http://www.jstatsoft.org/v08/i14/paper
  (let ((state seed))
    (lambda ()
      (let* ((y state)
             (y (bitwise-xor y (bitwise-arithmetic-shift y 13)))
             (y (bitwise-xor y (bitwise-arithmetic-shift y -17)))
             (y (bitwise-xor y (bitwise-arithmetic-shift y 5)))
             (y (bitwise-and y #xffffffff)))
        (set! state y)
        y))))

(define random-u32 (make-xorshift32 2463534242))

(define (random upper-limit)
  (mod (random-u32) upper-limit))

(define (random-int n)
  ;; Makes a random number in the range (-n, n)
  (- (random (- (* 2 n) 1)) (- n 1)))

;;; Test case generation

(define reg-names8 '(al cl dl bl ah ch dh bh))

(define reg-names16 '(ax cx dx bx sp bp si di))

(define reg-names32 '(eax ecx edx ebx esp ebp esi edi))

(define-record-type testcase
  (fields id mode text data)
  (protocol
   (lambda (p)
     (lambda (id mode text data)
       (p id mode text data)))))

(define-condition-type &unsupported-opsyntax &warning
  make-unsupported-opsyntax unsupported-opsyntax?)

;; Generate acceptable operands for an instruction opsyntax.
(define (generate-operands opsyntax*)
  (let lp ((opsyntax* opsyntax*)
           (ret* '())
           (operand-size #f))
    (cond ((null? opsyntax*)
           (reverse ret*))
          (else
           (case (car opsyntax*)
             ((*unity) (lp (cdr opsyntax*) (cons 1 ret*) operand-size))
             ((*CL) (lp (cdr opsyntax*) (cons 'cl ret*) operand-size))
             ((*AL) (lp (cdr opsyntax*) (cons 'al ret*) operand-size))
             ((*rAX)
              (let ((operand-size (or operand-size
                                      (case (random 2)
                                        ((0) 16)
                                        (else 32)))))
                (case operand-size
                  ((16)
                   (lp (cdr opsyntax*) (cons 'ax ret*) operand-size))
                  (else
                   (lp (cdr opsyntax*) (cons 'eax ret*) operand-size)))))
             ((Eb)
              (case (random 2)
                ;; TODO: memory
                (else (lp `(Gb ,@(cdr opsyntax*)) ret* operand-size))))
             ((Ew)
              (case (random 2)
                ;; TODO: memory
                (else (lp `(Gw ,@(cdr opsyntax*)) ret* operand-size))))
             ((Ev)
              (case (random 2)
                ;; TODO: memory
                (else (lp `(Gv ,@(cdr opsyntax*)) ret* operand-size))))
             ((Gb)
              (lp (cdr opsyntax*)
                  (cons (list-ref reg-names8 (random (length reg-names8))) ret*)
                  operand-size))
             ((Gw)
              (lp (cdr opsyntax*)
                  (cons (list-ref reg-names16 (random (length reg-names16))) ret*)
                  operand-size))
             ((Gv)
              ;; The operand size may have been chosen by a previous
              ;; operand. If not it may will be done here.
              (let ((operand-size (or operand-size
                                      (case (random 2)
                                        ((0) 16)
                                        (else 32)))))
                (case operand-size
                  ((16)
                   (lp `(Gw ,@(cdr opsyntax*)) ret* operand-size))
                  (else
                   (lp (cdr opsyntax*)
                       (cons (list-ref reg-names32 (random (length reg-names32))) ret*)
                       operand-size)))))
             ((Ib)
              (lp (cdr opsyntax*)
                  (cons (gen-reg 8) ret*)
                  operand-size))
             ((Iv Iz)
              (let ((operand-size (or operand-size
                                      (case (random 2)
                                        ((0) 16)
                                        (else 32)))))
                (lp (cdr opsyntax*)
                    (cons (gen-reg operand-size) ret*)
                    operand-size)))
             (else
              (raise (condition
                      (make-unsupported-opsyntax)
                      (make-irritants-condition (car opsyntax*))))))))))

;; Generate a register value.
(define (gen-reg class)
  (case class
    ((fl)
     (bitwise-and (gen-reg 16)
                  (bitwise-ior flag-OF flag-SF flag-ZF flag-AF flag-PF flag-CF flag-DF)))
    ((8 16 32)
     (bitwise-bit-field                 ;TODO: should not be needed
      (case (random 10)
        ((0) (random 4))
        ((1) (+ (- (expt 2 (- class 1)) 1) (random 4)))
        ((2) (random (expt 2 class)))
        ((3) (- (expt 2 class) 1 (random 4)))
        (else (+ (expt 2 (random (- class 1)))
                 (random-int 4))))
      0 class))
    (else
     (error 'gen-reg "Invalid register class" class))))

(define (generate-testcase instruction mode test-seq-no)
  ;; Generate test cases.
  (let ((mnemonic (car instruction))
        (opsyntax* (cdr instruction)))
    (let ((load-regs*
           (map (lambda (reg)
                  `(mov ,reg ,(gen-reg 32)))
                reg-names32))
          (load-flags*
           `((mov (mem32+ scratch-flags) ,(gen-reg 'fl))
             (mov esp scratch-flags)
             (popfd)))
          (test-instruction
           (cons mnemonic (generate-operands opsyntax*)))
          (id
           (call-with-string-output-port
             (lambda (p)
               (for-each (lambda (x)
                           (display x p)
                           (display #\- p))
                         instruction)
               (display test-seq-no p)))))
      (make-testcase
       id mode                          ;XXX: perhaps mode is useless
       `(,@load-flags*
         ,@load-regs*
         ,test-instruction)
       '()))))

(define (emulate-testcase testcase)
  (let ((M (make-machine)))
    (with-machine M
      (lambda ()
        ;; Setup the machine
        (let*-values (((machine-code symbol-table)
                       (assemble `((%origin #x1000)
                                   (%mode 16)
                                   ,@(testcase-text testcase)
                                   (sti)
                                   (hlt)
                                   (%align 512 0)
                                   (%label scratch-flags)
                                   (%u32 0)
                                   ,@(testcase-data testcase)))))
          (copy-to-memory #x1000 machine-code))

        ;; Emulate
        (machine-IP-set! M #x1000)
        (machine-CS-set! M #x0000)
        (machine-debug-set! M #f)
        (machine-run)

        ;; Return the result.
        `((eax . ,(machine-AX M))
          (ecx . ,(machine-CX M))
          (edx . ,(machine-DX M))
          (ebx . ,(machine-BX M))
          (esp . ,(machine-SP M))
          (ebp . ,(machine-BP M))
          (esi . ,(machine-SI M))
          (edi . ,(machine-DI M))
          (flags . ,(if *IGNORE-UNDEFINED-FLAGS?*
                        (fxand (machine-FLAGS M) (fxnot (machine-undefined-flags M)))
                        (machine-FLAGS M)))
          (flags-undef . ,(machine-undefined-flags M)))))))

;;; Test case selection

(define (gather-instructions table keep?)
  (let f ((instr table))
    (cond
      ((not instr) '())
      ((pair? instr)
       (case (car instr)
         ((*prefix*) '())
         (else
          (if (keep? instr)
              (list instr)
              '()))))
      (else
       (case (vector-ref instr 0)
         ((Group)
          (letrec ((walk-modr/m-table
                    (lambda (table)
                      (apply append
                             (map
                              (lambda (i)
                                (if (and (vector? i) (eqv? (vector-length i) 8))
                                    (apply append (map f (vector->list i)))
                                    (f i)))
                              (vector->list table))))))
            (append (walk-modr/m-table (vector-ref instr 2))
                    (if (> (vector-length instr) 3)
                        (walk-modr/m-table (vector-ref instr 3))
                        '()))))
         ((Prefix) (apply append (map f (cdr (vector->list instr)))))
         ((Datasize) (append (f (vector-ref instr 1)) (f (vector-ref instr 2))))
         ((Addrsize) (append (f (vector-ref instr 1)) (f (vector-ref instr 2))))
         ((Mode) (f (vector-ref instr 1)))
         ((Mem/reg) (append (vector-ref instr 1) (vector-ref instr 2)))
         (else
          (if (eqv? (vector-length instr) 256)
              (apply append (map f (vector->list instr)))
              '())))))))

;;; Code generation for test cases

(define (cg-testcase-32 testcase text data)
  ;; Generate code for a testcase (for 32-bit test runners).
  (let ((expected-result (emulate-testcase testcase)))
    (let ((expected-label (vector 'expected (testcase-id testcase)))
          (message-label (vector 'id (testcase-id testcase)))
          (message-label-end (vector 'id-end (testcase-id testcase)))
          (next-label (vector 'resume (testcase-id testcase)))
          (expected-reg* (map (lambda (reg) (cdr (assq reg expected-result)))
                              reg-names32))
          (expected-fl (cdr (assq 'flags expected-result))))
      (values `((mov (mem32+ current-testcase) ,message-label)
                (mov (mem32+ current-testcase-len) (- ,message-label-end ,message-label 1))
                (mov (mem32+ next-testcase) ,next-label)
                ,@(testcase-text testcase)
                ;; Dump registers to a temporary buffer
                ,@(let lp ((reg* reg-names32)
                           (i 0)
                           (code* '()))
                    (if (null? reg*)
                        (reverse code*)
                        (lp (cdr reg*)
                            (+ i 1)
                            `((mov (mem+ register-dump ,(* 4 i)) ,(car reg*))
                              ,@code*))))
                ;; Compare the flags register
                (mov esp (+ scratch-flags 4))
                (pushfd)
                ,@(if *IGNORE-UNDEFINED-FLAGS?*
                      (let ((undef (cdr (assq 'flags-undef expected-result))))
                        `((and (mem32+ esp) ,(fxnot undef))
                          (cmp (mem32+ esp) ,(fxand (fxnot undef) expected-fl))))
                      `((cmp (mem32+ esp) ,expected-fl)))
                (jne error)
                ;; Compare registers. TODO: repe.cmps
                ,@(let lp ((reg* reg-names32)
                           (i 0)
                           (code* '()))
                    (if (null? reg*)
                        (reverse code*)
                        (lp (cdr reg*)
                            (+ i 1)
                            `((jne error)
                              (cmp eax (mem+ ,expected-label ,(* 4 i)))
                              (mov eax (mem+ register-dump ,(* 4 i)))
                              ,@code*))))
                (%label ,next-label)
                ,@text)
              `(,@(testcase-data testcase)
                (%label ,message-label)
                (%utf8z ,(call-with-string-output-port
                           (lambda (p)
                             (display "\n\n\x1b;[1;31mTest failed: " p)
                             (display (testcase-id testcase) p)
                             (display "\x1b;[0m\n" p)
                             (for-each (lambda (instr)
                                         (define (hexlify x)
                                           (cond ((integer? x)
                                                  (string-append "#x" (number->string x 16)))
                                                 ((pair? x)
                                                  (cons (hexlify (car x))
                                                        (hexlify (cdr x))))
                                                 (else x)))
                                         (display (hexlify instr) p)
                                         (newline p))
                                       (testcase-text testcase))
                             (when *IGNORE-UNDEFINED-FLAGS?*
                               (display "Undefined flags have been cleared: #x" p)
                               (display (number->string (cdr (assq 'flags-undef expected-result)) 16) p)
                               (newline p))
                             (display "Result from emulation in Zabavno:\n" p)
                             (for-each (lambda (reg)
                                         (unless (eqv? (car reg) 'flags-undef)
                                           (write (car reg) p)
                                           (display "\t#x" p)
                                           (let ((str (number->string (cdr reg) 16)))
                                             (when (> (string-length str) 8)
                                               (error 'cg-testcase-32 "Bad register value"
                                                      str expected-result))
                                             (display (make-string (- 8 (string-length str)) #\0) p)
                                             (display str p))
                                           (newline p)))
                                       expected-result)
                             (display "Result from the machine:\n" p))))
                (%label ,message-label-end)
                (%align 4 0)
                (%label ,expected-label)
                (%u32 ,@expected-reg*)
                ,@data)))))

(define (syscall-write fd buf count)
  `((mov ebx ,fd)
    (mov ecx ,buf)
    (mov edx ,count)
    (mov eax 4)                         ;write
    (int #x80)))

(define (syscall-exit status)
  `((mov ebx ,status)
    (mov eax 1)                         ;exit
    (int #x80)))

(define lib-text
  `(;; test cases fall through to here
    (%comm exit-status 4 4)
    ,@(syscall-exit '(mem+ exit-status))

    ;; Show the status of failed test cases.
    (%label error)
    (mov esp (mem+ saved-esp))
    (mov (mem32+ exit-status) 1)
    ;; Print the message
    (%comm current-testcase 4 4)
    (%comm current-testcase-len 4 4)
    ,@(syscall-write 1 '(mem+ current-testcase) '(mem+ current-testcase-len))
    ;; Print the register dump
    (%comm register-dump ,(* (+ (length reg-names32) 1) 4) 4)
    (%comm scratch-flags 4 4)           ;XXX: remove
    ,@(let lp ((reg* reg-names32)
               (i 0)
               (code* '()))
        (cond ((null? reg*)
               code*)
              (else
               (lp (cdr reg*)
                   (+ i 1)
                   `(,@code*
                     ,@(syscall-write 1 `(+ register-headings ,(* i 7)) 6)
                     (mov edx (mem+ register-dump ,(* i 4)))
                     (call print-edx))))))
    ,@(syscall-write 1 'flags-str 8)
    (mov edx (mem32+ scratch-flags))
    (call print-edx)
    ;; Goto the next testcase
    (%comm next-testcase 4 4)
    (jmp (mem32+ next-testcase))

    ;; Print the contents of edx
    (%label print-edx)
    (%comm print-edx-tmp 9 1)
    ,@(let ((loop (vector 'loop)))
        `((mov ecx 8)
          (%label ,loop)
          (mov eax edx)
          (shr edx 4)
          (and eax #xf)
          (mov al (mem+ hex-digits eax))
          (mov (mem8+ print-edx-tmp ecx -1) al)
          (sub ecx 1)
          (jnz ,loop)))
    (mov (mem8+ print-edx-tmp 8) ,(char->integer #\newline))
    ,@(syscall-write 1 'print-edx-tmp 9)
    (ret)

    ;; Print an informative greeting.
    (%label print-greeting)
    ,@(syscall-write 1 'greeting '(- greeting-end greeting 1))
    (ret)

    ;; The first function that runs.
    (%label init)
    (%comm saved-esp 4 4)
    (mov (mem+ saved-esp) esp)
    (call print-greeting)
    (ret)))

(define lib-data
  `((%label greeting)
    (%utf8z "Zabavno x86 test suite\n\
Exit status:\n\
 0 - success\n\
 1 - a failed test case\n\
 2 - test case could not be emulated (see generate.sps output)\n\n")
    (%label greeting-end)
    (%label hex-digits)
    (%utf8z "0123456789ABCDEF")

    ;; Make a table of register headings (all length 7), for printing.
    (%align 4)
    (%label register-headings)
    ,@(map (lambda (reg)
             `(%utf8z ,(call-with-string-output-port
                         (lambda (p)
                           (display reg p)
                           (display "\t#x" p)))))
           reg-names32)
    (%label flags-str)
    (%utf8z "flags\t#x")))


(define (generate-testcases instruction mode n)
  (do ((i 0 (+ i 1))
       (testcase* '() (cons (generate-testcase instruction mode i) testcase*)))
      ((= i n)
       testcase*)))

(define (cg-testcases testcase* text data)
  (let lp ((testcase* testcase*)
           (text text)
           (data data))
    (if (null? testcase*)
        (values text data)
        (guard (con
                ((serious-condition? con)
                 (display "Test case can not be emulated: " (current-error-port))
                 (display (car testcase*) (current-error-port))
                 (newline (current-error-port))
                 (cond ((who-condition? con)
                        (write (condition-who con) (current-error-port))
                        (newline (current-error-port))))
                 (cond ((message-condition? con)
                        (write (condition-message con) (current-error-port))
                        (newline (current-error-port))))
                 (cond ((irritants-condition? con)
                        (write (condition-irritants con) (current-error-port))
                        (newline (current-error-port))))
                 (lp (cdr testcase*)
                     `((mov (mem32+ exit-status) 2)
                       ,@text) data)))
          (let-values (((text^ data^) (cg-testcase-32 (car testcase*) text data)))
            (lp (cdr testcase*) text^ data^))))))

(define (generate-test-image filename instruction*)
  (let lp ((text '())
           (data '())
           (instruction* instruction*))
    (cond ((null? instruction*)
           (when (file-exists? filename)
             (delete-file filename))
           (make-x86-elf-image filename
                               `((call init)
                                 ,@text
                                 ,@lib-text)
                               `(,@data
                                 ,@lib-data)))
          (else
           (display "Generating code for ")
           (display (car instruction*))
           (newline)
           (let-values (((text data) (cg-testcases (generate-testcases (car instruction*) 32 100)
                                                   text data)))
             (lp text data (cdr instruction*)))))))

;;; Main program

(define (main filename)
  (let ((instructions
         (gather-instructions opcodes
                              (lambda (instr)
                                (and (memq (car instr) *TEST-MNEMONICS*)
                                     (guard (exn
                                             ((unsupported-opsyntax? exn)
                                              (display "Unsupported opsyntax ")
                                              (write (condition-irritants exn))
                                              (display " in instruction ")
                                              (write instr)
                                              (newline)
                                              #f))
                                       (generate-operands (cdr instr))))))))
    (display "Writing ")
    (display filename)
    (newline)
    (generate-test-image filename instructions)))

(main "generate.out")
