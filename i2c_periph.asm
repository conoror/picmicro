;  This is code to show how to implement an I2C Peripheral on a midrange
;  PIC (eg: PIC16F88). The enhanced midrange have more registers to solve
;  some of the difficulties presented by the older I2C implementations.
;  It is way harder than it looks to create a robust I2C Peripheral
;  on these. (Note: "Peripheral" is my (and NXP's) preferred term.)
;
;  There is existing code out there to do this but the idea of this
;  code is to be as robust and as clear as I possibly make it.
;  The code has been tested including edge cases like forcing an
;  overflow condition. I used a digital analyser to catch these cases.
;
;  Even so, there is a single case remaining. In the case of an exchange
;  which never completes (eg: reset on the master side), there is every
;  possibility of the I2C bus hanging up. This requires an I2C watchdog
;  to be implemented. This is not done in this code as I need to create
;  a broken I2C controller to test it.
;
;  Distribution and use of this software are as per the terms of the
;  Simplified BSD License (also known as the "2-Clause License")
;
;  Copyright 2012 Conor F. O'Rourke. All rights reserved.
;


; ---- Processor and Config -----------------------------------------

        processor   pic16f88
        #include    p16f88.inc
        #include    macrosp16.inc

        {{
            I use a few basic macros to help my brain with btfss etc
            but I do use them in this code extensively. The macros
            are present in the repository.

            I put clarifing comments in these brackets as it's not code.
            Needless to say, this won't compile!

            One thing - I don't assume any particular radix. But I
            do think a default radix of "hex" by Microchip is really
            silly. Why? Well. Is "BF" a define or a number?
        }}


; ---- Defines and equates ------------------------------------------

        {{
            I find the PIC documentation to be vague as regards the
            address. They use an 8-bit address not the usual 7-bit.
            By explicitly doing the shift, I'm pointing that out.
        }}

        #define I2CADDR         0x5B << 1
        #define I2CISXMIT       i2c_isxmit, 0
        #define I2CISFIRST      i2c_isfirst, 0
        #define I2CISNEXT       i2c_isfirst, 1

        #define I2CGOODCMD      i2c_cmd, 7


; ---- Variables ----------------------------------------------------

        CBLOCK 0x20                 ; Bank 0
            i2c_isxmit              ; i2c variables are assumed Bank0
            i2c_isfirst
            i2c_stat
            i2c_cmd
            i2c_value
        ENDC

        {{
            I do assume in my code that the I2C variables are held in Bank0.
            i2c_isxmit, i2c_isfirst are flags used by the ISR. By "Transmit"
            I mean master read. This is the peripheral so we transmit on read.

            i2c_isfirst is two flags (ok, bad naming maybe). ISFIRST means
            we've started receiving and ISNEXT means we've got the first
            byte (command) and are now waiting for the value.

            i2c_stat,cmd and value are implementations that I happen to be
            using and you could change these as you see fit:

             i2c_stat: a status register. Eg: key presses. fan on/off
                       an I2C read returns this register over and over

             i2c_cmd:  I use an i2c write as: command/value. i2c_cmd
                       hold the command. The high bit means I got a
                       good command and I can use the value in i2c_value.
                       Yes, it's a bit of a hack. I clear this bit when
                       I process the command so I know it's done.

             i2c_value: The value that goes with command
        }}

        CBLOCK 0x70                 ; On all banks
            temp_w
            temp_status
        ENDC



; ==== Reset Vector =================================================

        org         0x0000
        goto        Init


; ---- ISR Entry Point ----------------------------------------------

        org         0x0004

        movwf       temp_w
        movf        STATUS, W
        movwf       temp_status

        banksel     PIR1                    ; Bank0

        ifbset      PIR1, SSPIF             ; I2C
          goto      IsrI2CEntry

        {{
            You could put other tests in there for Timer1 etc. It's
            all about priority. I felt that my Timer1 could wait 100us!
        }}

        goto        IsrExit                 ; Everything else


        ; ---- I2C Peripheral ISR Handling ----

IsrI2CEntry:

        bcf         PIR1, SSPIF             ; Clear SSP Interrupt Flag

        ; Is the buffer address or data?

        banksel     SSPSTAT
        ifbset      SSPSTAT, D_NOT_A
          goto      IsrI2CData

        ; == It's an address ==
        ;   R/W# is valid here but few other places
        ;   Copy R/W# bit into i2c_isxmit
        ;   Set first byte flag

        clrw
        ifbset      SSPSTAT, R_NOT_W
          movlw     0x01
        banksel     i2c_isxmit              ; Bank0/SSPCON/SSPBUF
        movwf       i2c_isxmit

        {{
            Getting the address means the start of a sequence. So
            you could reset pointers or whatever you need to get
            ready. I just set a first flag and clear the next flag
        }}

        bsf         I2CISFIRST              ; Or reset pointers etc
        bcf         I2CISNEXT

        ; SSPBUF has I2C address:
        ;   On receive, SSPBUF must be read to clear BF
        ;   No side effects in reading SSPBUF on transmit
        ;   Read SSPBUF before checking overflow to avoid races

        movf        SSPBUF, W

        ifbset      I2CISXMIT
          goto      IsrI2CData

        ; == Address + Receive ==
        ;   Check for overflow and exit

        ifbset      SSPCON, SSPOV           ; Check overflow
          goto      IsrI2COverflow

        goto        IsrExit                 ; ---- Done ----


IsrI2CData:
        ; == Data Transmit or Receive ==
        ;   Transmit may be right after address. (D_NOT_A == 1 or 0)
        ;   Receive will be the next cycle (D_NOT_A == 1).

        banksel     i2c_isxmit              ; Bank0/SSPCON/SSPBUF (necessary)
        ifbset      I2CISXMIT
          goto      IsrI2CTransmit

        ; == Receiving data ==

        ; BF should be 1 here. If it's 0 something went badly
        ; wrong. Like not clearing SSPIF on an Overflow. Unlikely!

        banksel     SSPSTAT
        ifbclr      SSPSTAT, BF
          goto      IsrI2COverflow

        banksel     SSPCON
        movf        SSPBUF, W

        ; First byte is command, next byte is data. Once data is stored
        ; set high bit on cmd to signal a good command. If that high bit
        ; is already set, there was some sort of race problem

        ifbclr      I2CISFIRST
          goto      IsrI2CRecvDone

        ifbclr      I2CISNEXT
          goto      IsrI2CRecvFirst

        ; Second byte is the value. No more data after this:

        movwf       i2c_value
        bsf         I2CGOODCMD
        clrf        i2c_isfirst
        goto        IsrI2CRecvDone

IsrI2CRecvFirst:
        ifbset      I2CGOODCMD
          clrf      i2c_isfirst
        ifbset      I2CGOODCMD
          goto      IsrI2CRecvDone

        movwf       i2c_cmd
        bcf         I2CGOODCMD
        bsf         I2CISNEXT

IsrI2CRecvDone:
        ; If BF is set, data will be valid. However if an Overflow occurs
        ; (which will not overwrite SSPBUF), SSPOV *and* SSPIF are set.
        ; Read SSPBUF _before_ checking overflow to avoid race conditions.

        ifbset      SSPCON, SSPOV
          goto      IsrI2COverflow

        goto        IsrExit                 ; ---- Done ----


IsrI2CTransmit:
        ; Transmitting data iff master ACK last time
        ; Clock should be halted (CKP==0) if continuing (not NACK)
        ; R/W# indicates the status of last ACK
        ; Master NACK if R/W# is 0. Can check CKP too to be sure

        banksel     SSPSTAT
        ifbclr      SSPSTAT, R_NOT_W
          goto      IsrI2CMasterNack

        banksel     SSPCON                  ; SSPCON/SSPBUF
        ifbset      SSPCON, CKP
          goto      IsrI2CMasterNack

        ; == Transmit byte ==

        bcf         SSPCON, SSPOV           ; Hmm. I suppose I should clear
        bcf         SSPCON, WCOL            ; these before collision checks

        movf        i2c_stat, W
        movwf       SSPBUF                  ; Send data - BF set

        {{
            I thought this was neat. Reading certain statuses like
            keystrokes can be problematic. What you want to do is
            read them once and then note you did that. What I do
            is set the key status in i2c_stat and then clear them
            when I know they've been read. Which is here. The
            defines are personal to my code so they aren't here:
        }}

        ; Fetching keystates autoclears them; thus we get them once...
        bcf         i2c_stat, CMD_BIT_SKEY
        bcf         i2c_stat, CMD_BIT_LKEY

        ifbset      SSPCON, WCOL
          goto      IsrI2CWriteCol

        ; Wait a setup time (check for wcol will cover that)

        bsf         SSPCON, CKP             ; Start the clock back up
        goto        IsrExit                 ; --- Done ---


IsrI2CMasterNack:
        banksel     SSPCON
        movf        SSPBUF, W               ; Mostly pedantic
        bcf         SSPCON, SSPOV
        bcf         SSPCON, WCOL
        bsf         SSPCON, CKP
        goto        IsrExit                 ; --- Done ---


IsrI2CWriteCol:
IsrI2COverflow:
        ; == Game over. I2C cycle ends. No ACK from us ==
        ;   Just clear everything. NOTE: SSPOV sets SSPIF.
        ;   Write collision handling done here (like AN734)

        banksel     SSPCON                  ; Bank0/SSPBUF/SSPCON/PIR1
        movf        SSPBUF, W               ; Clear BF
        bcf         SSPCON, SSPOV
        bcf         SSPCON, WCOL
        bsf         SSPCON, CKP             ; For the write collision case
        bcf         PIR1, SSPIF             ; MUST clear the pending IRQ
        goto        IsrExit                 ; --- Done ---




        ; ---- OTHER ISR Handling here ----

        {{
            Timer is most obvious
        }}




        ; ---- ISR Exit point ----

IsrExit:
        movf        temp_status, W
        movwf       STATUS
        swapf       temp_w, F       ; Don't change status register
        swapf       temp_w, W

        retfie




; ==== Main code ====================================================

; ---- Initialisation -----------------------------------------------

Init:
        ; == Ports and Oscillator Config ==

        {{
            The usual code would be here
        }}


        ; == I2C Initialisation ==

        banksel     i2c_stat
        clrf        i2c_isxmit
        clrf        i2c_isfirst
        clrf        i2c_stat
        clrf        i2c_cmd
        clrf        i2c_value

        banksel     SSPADD                  ; SSPADD/PIE1
        movlw       I2CADDR
        movwf       SSPADD                  ; Set address

        {{
            etc
        }}

