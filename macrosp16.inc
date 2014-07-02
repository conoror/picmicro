; PIC16 Macros

ifbset  MACRO file, bit
        btfsc file, bit
        ENDM

ifbclr  MACRO file, bit
        btfss file, bit
        ENDM

ifz     MACRO
        btfsc STATUS, Z
        ENDM

ifnz    MACRO
        btfss STATUS, Z
        ENDM

tstw    MACRO
        xorlw 0
        ENDM

sbankx0 MACRO
        bcf STATUS, RP0
        ENDM

sbankx1 MACRO
        bsf STATUS, RP0
        ENDM

sbank0x MACRO
        bcf STATUS, RP1
        ENDM

sbank1x MACRO
        bsf STATUS, RP1
        ENDM

