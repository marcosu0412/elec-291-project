; This example uses a technique called "decimation" with the 8-bit ADC
; to increase its efective resolution to 12-bits.  The output of a LM335
; tempererature sensor is read and then diplayed using PUTTy in degrees Celcius.
;
; Some good information about decimation found here:
;
; https://www.cypress.com/file/236481/download

$NOLIST
$MOD9351
$LIST

XTAL EQU 7373000
BAUD EQU 115200
BRVAL EQU ((XTAL/BAUD)-16)

	CSEG at 0x0000
	ljmp	MainProgram

DSEG at 0x30
x:   ds 4
y:   ds 4
bcd: ds 5

BSEG
mf: dbit 1

$NOLIST
$INCLUDE(math32.inc)
$LIST

putchar:
	jbc	TI,putchar_L1
	sjmp putchar
putchar_L1:
	mov	SBUF,a
	ret
	
getchar:
	jbc	RI,getchar_L1
	sjmp getchar
getchar_L1:
	mov	a,SBUF
	ret

Wait1S:
	mov R2, #40
L3:	mov R1, #250
L2:	mov R0, #184
L1:	djnz R0, L1 ; 2 machine cycles-> 2*0.27126us*184=100us
	djnz R1, L2 ; 100us*250=0.025s
	djnz R2, L3 ; 0.025s*40=1s
	ret

InitSerialPort:
	mov	BRGCON,#0x00
	mov	BRGR1,#high(BRVAL)
	mov	BRGR0,#low(BRVAL)
	mov	BRGCON,#0x03 ; Turn-on the baud rate generator
	mov	SCON,#0x52 ; Serial port in mode 1, ren, txrdy, rxempty
	mov	P1M1,#0x00 ; Enable pins RxD and TXD
	mov	P1M2,#0x00 ; Enable pins RxD and TXD
	ret

InitADC:
	; ADC0_0 is connected to P1.7
	; ADC0_1 is connected to P0.0
	; ADC0_2 is connected to P2.1
	; ADC0_3 is connected to P2.0
    ; Configure pins P1.7, P0.0, P2.1, and P2.0 as inputs
    orl P0M1, #00000001b
    anl P0M2, #11111110b
    orl P1M1, #10000000b
    anl P1M2, #01111111b
    orl P2M1, #00000011b
    anl P2M2, #11111100b
	; Setup ADC0
	setb BURST0 ; Autoscan continuos conversion mode
	mov	ADMODB,#0x20 ;ADC0 clock is 7.3728MHz/2
	mov	ADINS,#0x0f ; Select the four channels of ADC0 for conversion
	mov	ADCON0,#0x05 ; Enable the converter and start immediately
	; Wait for first conversion to complete
InitADC_L1:
	mov	a,ADCON0
	jnb	acc.3,InitADC_L1
	ret

HexAscii: db '0123456789ABCDEF'

SendTemp:
	mov dptr, #HexAscii 
	
	mov a, bcd+2
	swap a
	anl a, #0xf
	movc a, @a+dptr
	lcall putchar
	mov a, bcd+2
	anl a, #0xf
	movc a, @a+dptr
	lcall putchar
	
	mov a, bcd+1
	swap a
	anl a, #0xf
	movc a, @a+dptr
	lcall putchar
	mov a, bcd+1
	anl a, #0xf
	movc a, @a+dptr
	lcall putchar

	mov a, #'.'
	lcall putchar

	mov a, bcd+0
	swap a
	anl a, #0xf
	movc a, @a+dptr
	lcall putchar
	mov a, bcd+0
	anl a, #0xf
	movc a, @a+dptr
	lcall putchar
	
	mov a, #'\r'
	lcall putchar
	mov a, #'\n'
	lcall putchar	
	ret
	
SendString:
    clr a
    movc a, @a+dptr
    jz SendString_L1
    lcall putchar
    inc dptr
    sjmp SendString  
SendString_L1:
	ret

Wait10us:
    mov R0, #18
    djnz R0, $ ; 2 machine cycles-> 2*0.27126us*18=10us
	ret

InitialMessage: db '\r\nP89LPC9351 ADC decimation example.\r\n', 0
	
MainProgram:
    mov SP, #0x7F
	lcall InitSerialPort
	lcall InitADC

	lcall Wait1S ; Wait a bit so PUTTy has a chance to start
	mov dptr, #InitialMessage
	lcall SendString

forever_loop:
	; Take 256 (4^4) consecutive measurements of ADC0 channel 0 at about 10 us intervals and accumulate in x
	Load_x(0)
    mov x+0, AD0DAT3
	mov R7, #255
    lcall Wait10us
accumulate_loop:
    mov y+0, AD0DAT3
    mov y+1, #0
    mov y+2, #0
    mov y+3, #0
    lcall add32
    lcall Wait10us
	djnz R7, accumulate_loop
	
	; Now divide by 16 (2^4)
	Load_Y(16)
	lcall div32
	; x has now the 12-bit representation of the temperature
	
	; Convert to temperature (C)
	Load_Y(33000) ; Vref is 3.3V
	lcall mul32
	Load_Y(((1<<12)-1)) ; 2^12-1
	lcall div32
	Load_Y(27300)
	lcall sub32
	
;	lcall hex2bcd
	
	;lcall SendTemp ; Send to PUTTy, with 2 decimal digits to show that it actually works

	
forever_loop_2:	
	mov R4, x+0
	mov R5, x+1

	Load_x(0)
    mov x+0, AD0DAT0

	Load_Y(330)
	lcall mul32
	Load_Y(255)
	lcall div32
	Load_Y(74)
	lcall mul32
	Load_Y(0)
	mov a,#0
	mov a, R4
	mov y+0,a
	mov a,#0
	mov a, R5
	mov y+1,a
	lcall add32

	lcall hex2bcd
	
	lcall SendTemp ; Send to PUTTy, with 2 decimal digits to show that it actually works
	lcall Wait1S

	ljmp forever_loop
end
