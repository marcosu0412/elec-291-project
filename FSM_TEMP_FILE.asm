; Talking_Stop_Watch.asm:  The name says it all!
; P2.6 is the START push button
; P3.0 is the STOP push button.  Pressing this button plays the ellapsed time.
; P0.3 is the CLEAR push button.
; The SPI flash memory is assumed to be loaded with 'stop_watch.wav'
; The state diagram of the playback FSM is available as 'Stop_Watch_FSM.pdf'
;
; Copyright (C) 2012-2019  Jesus Calvino-Fraga, jesusc (at) ece.ubc.ca
; 
; This program is free software; you can redistribute it and/or modify it
; under the terms of the GNU General Public License as published by the
; Free Software Foundation; either version 2, or (at your option) any
; later version.
; 
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
; 
; You should have received a copy of the GNU General Public License
; along with this program; if not, write to the Free Software
; Foundation, 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
; 
; Connections:
; 
; P89LPC9351  SPI_FLASH
; P2.5        Pin 6 (SPI_CLK)
; P2.2        Pin 5 (MOSI)
; P2.3        Pin 2 (MISO)
; P2.4        Pin 1 (CS/)
; GND         Pin 4
; 3.3V        Pins 3, 7, 8
;
; P0.4 is the DAC output which should be connected to the input of an amplifier (LM386 or similar)
;
; P2.6, P3.0, and P0.3 are connected to push buttons
;
; LCD uses pins P0.5, P0.6, P0.7, P1.2, P1.3, P1.4, P1.6
; WARNING: P1.2 and P1.3 need each a 1k ohm pull-up resistor to VCC (according to the datasheet!).
;
; P2.7 is used (with a transistor) to turn the speaker on/off so it doesn't have a clicking sound.  Use a NPN BJT
; like the 2N3904 or 2N2222A.  The emitter is connected to GND.  The base is connected to a 330 ohm resistor
; and pin P2.7; the other pin of the resistor is connected to 5V.  The collector is connected to the '-'
; terminal of the speaker.
;

$NOLIST
$MOD9351
$LIST

CLK         EQU 14746000  ; Microcontroller system clock frequency in Hz
CCU_RATE    EQU 22050     ; 22050Hz is the sampling rate of the wav file we are playing
CCU_RELOAD  EQU ((65536-((CLK/(2*CCU_RATE)))))
BAUD        EQU 115200
BRVAL       EQU ((CLK/BAUD)-16)

TIMER1_RATE   EQU 200     ; 200Hz, for a timer tick of 5ms
TIMER1_RELOAD EQU ((65536-(CLK/(2*TIMER1_RATE))))

FLASH_CE    EQU P2.4
SOUND       EQU P2.7

; Commands supported by the SPI flash memory according to the datasheet
WRITE_ENABLE     EQU 0x06  ; Address:0 Dummy:0 Num:0
WRITE_DISABLE    EQU 0x04  ; Address:0 Dummy:0 Num:0
READ_STATUS      EQU 0x05  ; Address:0 Dummy:0 Num:1 to infinite
READ_BYTES       EQU 0x03  ; Address:3 Dummy:0 Num:1 to infinite
READ_SILICON_ID  EQU 0xab  ; Address:0 Dummy:3 Num:1 to infinite
FAST_READ        EQU 0x0b  ; Address:3 Dummy:1 Num:1 to infinite
WRITE_STATUS     EQU 0x01  ; Address:0 Dummy:0 Num:1
WRITE_BYTES      EQU 0x02  ; Address:3 Dummy:0 Num:1 to 256
ERASE_ALL        EQU 0xc7  ; Address:0 Dummy:0 Num:0
ERASE_BLOCK      EQU 0xd8  ; Address:3 Dummy:0 Num:0
READ_DEVICE_ID   EQU 0x9f  ; Address:0 Dummy:2 Num:1 to infinite

dseg at 30H
w:             ds 3 ; 24-bit play counter.  Decremented in CCU ISR.
minutes:       ds 1
seconds:       ds 1
T2S_FSM_state: ds 1
Count5ms:      ds 1
FSMState:	   ds 1
BCD:		   ds 5

BSEG
T2S_FSM_start: dbit 1
seconds_flag:  dbit 1
Sec5:		   dbit 1

; Connect pushbuttons to this pins to, start, stop, or clear the stop watch
START equ P2.6
STOP  equ P3.0
CLEAR equ P0.3

cseg

org 0x0000 ; Reset vector
    ljmp MainProgram

org 0x0003 ; External interrupt 0 vector (not used in this code)
	reti

org 0x000B ; Timer/Counter 0 overflow interrupt vector (not used in this code)
	reti

org 0x0013 ; External interrupt 1 vector (not used in this code)
	reti

org 0x001B ; Timer/Counter 1 overflow interrupt vector
	ljmp Timer1_ISR

org 0x0023 ; Serial port receive/transmit interrupt vector (not used in this code)
	reti

org 0x005b ; CCU interrupt vector.  Used in this code to replay the wave file.
	ljmp CCU_ISR

cseg
; These 'equ' must match the wiring between the microcontroller and the LCD!
LCD_RS equ P0.5
LCD_RW equ P0.6
LCD_E  equ P0.7
LCD_D4 equ P1.2
LCD_D5 equ P1.3
LCD_D6 equ P1.4
LCD_D7 equ P1.6
$NOLIST
$include(LCD_4bit_LPC9351.inc) ; A library of LCD related functions and utility macros
$LIST

;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 1                     ;
;---------------------------------;
Timer1_Init:
	mov a, TMOD
	anl a, #0x0f ; Clear the bits for timer 1
	orl a, #0x10 ; Configure timer 1 as 16-timer
	mov TMOD, a
	mov TH1, #high(TIMER1_RELOAD)
	mov TL1, #low(TIMER1_RELOAD)
	; Enable the timer and interrupts
    setb ET1  ; Enable timer 1 interrupt
    setb TR1  ; Start timer 1
	ret

;---------------------------------;
; ISR for timer 1                 ;
;---------------------------------;
Timer1_ISR:
	mov TH1, #high(TIMER1_RELOAD)
	mov TL1, #low(TIMER1_RELOAD)
	
	; The two registers used in the ISR must be saved in the stack
	push acc
	push psw
	
	; Increment the 8-bit 5-mili-second counter
	inc Count5ms

Inc_Done:
	; Check if half second has passed
	mov a, Count5ms
	cjne a, #200, Timer1_ISR_done ; Warning: this instruction changes the carry flag!
	
	; 1000 milliseconds have passed.  Set a flag so the main program knows
	setb seconds_flag ; Let the main program know half second had passed
	; Reset to zero the 5-milli-seconds counter, it is a 8-bit variable
	mov Count5ms, #0
	; Increment minutes and seconds
	inc seconds
	mov a, seconds
	cjne a, #60, Timer1_ISR_done
	mov seconds, #0
	inc minutes
	mov a, minutes
	cjne a, #60, Timer1_ISR_done
	mov minutes, #0
	
Timer1_ISR_done:
	pop psw
	pop acc
	reti

;---------------------------------;
; Routine to initialize the CCU.  ;
; We are using the CCU timer in a ;
; manner similar to the timer 2   ;
; available in other 8051s        ;
;---------------------------------;
CCU_Init:
	mov TH2, #high(CCU_RELOAD)
	mov TL2, #low(CCU_RELOAD)
	mov TOR2H, #high(CCU_RELOAD)
	mov TOR2L, #low(CCU_RELOAD)
	mov TCR21, #10000000b ; Latch the reload value
	mov TICR2, #10000000b ; Enable CCU Timer Overflow Interrupt
	setb ECCU ; Enable CCU interrupt
	setb TMOD20 ; Start CCU timer
	ret

;---------------------------------;
; ISR for CCU.  Used to playback  ;
; the WAV file stored in the SPI  ;
; flash memory.                   ;
;---------------------------------;
CCU_ISR:
	mov TIFR2, #0 ; Clear CCU Timer Overflow Interrupt Flag bit. Actually, it clears all the bits!
	
	; The registers used in the ISR must be saved in the stack
	push acc
	push psw
	
	; Check if the play counter is zero.  If so, stop playing sound.
	mov a, w+0
	orl a, w+1
	orl a, w+2
	jz stop_playing
	
	; Decrement play counter 'w'.  In this implementation 'w' is a 24-bit counter.
	mov a, #0xff
	dec w+0
	cjne a, w+0, keep_playing
	dec w+1
	cjne a, w+1, keep_playing
	dec w+2
	
keep_playing:

	lcall Send_SPI ; Read the next byte from the SPI Flash...
	mov AD1DAT3, a ; and send it to the DAC
	
	sjmp CCU_ISR_Done

stop_playing:
	clr TMOD20 ; Stop CCU timer
	setb FLASH_CE  ; Disable SPI Flash
	clr SOUND ; Turn speaker off

CCU_ISR_Done:	
	pop psw
	pop acc
	reti

;---------------------------------;
; Initial configuration of ports. ;
; After reset the default for the ;
; pins is 'Open Drain'.  This     ;
; routine changes them pins to    ;
; Quasi-bidirectional like in the ;
; original 8051.                  ;
; Notice that P1.2 and P1.3 are   ;
; always 'Open Drain'. If those   ;
; pins are to be used as output   ;
; they need a pull-up resistor.   ;
;---------------------------------;
Ports_Init:
    ; Configure all the ports in bidirectional mode:
    mov P0M1, #00H
    mov P0M2, #00H
    mov P1M1, #00H
    mov P1M2, #00H ; WARNING: P1.2 and P1.3 need 1 kohm pull-up resistors if used as outputs!
    mov P2M1, #00H
    mov P2M2, #00H
    mov P3M1, #00H
    mov P3M2, #00H
	ret

;---------------------------------;
; Initialize ADC1/DAC1 as DAC1.   ;
; Warning, the ADC1/DAC1 can work ;
; only as ADC or DAC, not both.   ;
; The P89LPC9351 has two ADC/DAC  ;
; interfaces.  One can be used as ;
; ADC and the other can be used   ;
; as DAC.  Also configures the    ;
; pin associated with the DAC, in ;
; this case P0.4 as 'Open Drain'. ;
;---------------------------------;
InitDAC1:
    ; Configure pin P0.4 (DAC1 output pin) as open drain
	orl	P0M1,   #00010000B
	orl	P0M2,   #00010000B
    mov ADMODB, #00101000B ; Select main clock/2 for ADC/DAC.  Also enable DAC1 output (Table 25 of reference manual)
	mov	ADCON1, #00000100B ; Enable the converter
	mov AD1DAT3, #0x80     ; Start value is 3.3V/2 (zero reference for AC WAV file)
	ret

;---------------------------------;
; Change the internal RC osc. clk ;
; from 7.373MHz to 14.746MHz.     ;
;---------------------------------;
Double_Clk:
    mov dptr, #CLKCON
    movx a, @dptr
    orl a, #00001000B ; double the clock speed to 14.746MHz
    movx @dptr,a
	ret

;---------------------------------;
; Initialize the SPI interface    ;
; and the pins associated to SPI. ;
;---------------------------------;
Init_SPI:
	; Configure MOSI (P2.2), CS* (P2.4), and SPICLK (P2.5) as push-pull outputs (see table 42, page 51)
	anl P2M1, #low(not(00110100B))
	orl P2M2, #00110100B
	; Configure MISO (P2.3) as input (see table 42, page 51)
	orl P2M1, #00001000B
	anl P2M2, #low(not(00001000B)) 
	; Configure SPI
	mov SPCTL, #11010000B ; Ignore /SS, Enable SPI, DORD=0, Master=1, CPOL=0, CPHA=0, clk/4
	ret

;---------------------------------;
; Sends AND receives a byte via   ;
; SPI.                            ;
;---------------------------------;
Send_SPI:
	mov SPDAT, a
Send_SPI_1:
	mov a, SPSTAT 
	jnb acc.7, Send_SPI_1 ; Check SPI Transfer Completion Flag
	mov SPSTAT, a ; Clear SPI Transfer Completion Flag
	mov a, SPDAT ; return received byte via accumulator
	ret

;---------------------------------;
; SPI flash 'write enable'        ;
; instruction.                    ;
;---------------------------------;
Enable_Write:
	clr FLASH_CE
	mov a, #WRITE_ENABLE
	lcall Send_SPI
	setb FLASH_CE
	ret

;---------------------------------;
; This function checks the 'write ;
; in progress' bit of the SPI     ;
; flash memory.                   ;
;---------------------------------;
Check_WIP:
	clr FLASH_CE
	mov a, #READ_STATUS
	lcall Send_SPI
	mov a, #0x55
	lcall Send_SPI
	setb FLASH_CE
	jb acc.0, Check_WIP ;  Check the Write in Progress bit
	ret
	
; Display a binary number in the LCD (must be less than 99).  Number to display passed in accumulator.
LCD_number:
	push acc
	mov b, #10
	div ab
	orl a, #'0'
	lcall ?WriteData
	mov a, b
	orl a, #'0'
	lcall ?WriteData
	pop acc
	ret

; Sounds we need in the SPI flash: 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 13; 14; 15; 16; 17; 18; 19; 20; 30; 40; 50; minutes; seconds;
; Approximate index of sounds in file 'stop_watch.wav'
; This was generated using: computer_sender -Asw_index.asm -S2000 stop_watch.wav
; Approximate index of sounds in file 'uwu.wav'
; Approximate index of sounds in file 'fuckme7.wav'
sound_index:
    db 0x00, 0x00, 0x2d ; 0 
    db 0x00, 0x31, 0x88 ; 1 
    db 0x00, 0x6f, 0xfe ; 2 
    db 0x00, 0xad, 0x21 ; 3 
    db 0x00, 0xf1, 0x8b ; 4 
    db 0x01, 0x37, 0x8c ; 5 
    db 0x01, 0x81, 0xd2 ; 6 
    db 0x01, 0xcf, 0x06 ; 7 
    db 0x02, 0x1b, 0x0e ; 8 
    db 0x02, 0x50, 0xff ; 9 
    db 0x02, 0x98, 0xb2 ; 10 
    db 0x02, 0xdd, 0x06 ; 11 
    db 0x03, 0x2b, 0x28 ; 12 
    db 0x03, 0x78, 0x79 ; 13 
    db 0x03, 0xc8, 0x78 ; 14 
    db 0x04, 0x1f, 0xe2 ; 15 
    db 0x04, 0x73, 0xea ; 16 
    db 0x04, 0xcf, 0x6d ; 17 
    db 0x05, 0x34, 0x7b ; 18 
    db 0x05, 0x7f, 0xca ; 19 
    db 0x05, 0xdb, 0x2d ; 20 
    db 0x06, 0x27, 0xad ; 21 
    db 0x06, 0x6a, 0xaf ; 22 
    db 0x06, 0xb3, 0x94 ; 23 
    db 0x06, 0xfb, 0x69 ; 24 
    db 0x07, 0x51, 0xf3 ; 25 
    db 0x07, 0xa9, 0xac ; 26 
    db 0x07, 0xeb, 0x4c ; 27 
    db 0x08, 0x38, 0x9c ; 28 
    db 0x08, 0x88, 0x9e ; 29 
    db 0x08, 0xfe, 0xb1 ; 30 
    db 0x09, 0x7d, 0x22 ; 31 
    db 0x09, 0xe9, 0x62 ; 32 
    db 0x0a, 0x2b, 0x40 

; Size of each sound in 'sound_index'
Size_length:
    db 0x00, 0x31, 0x5b ; 0 
    db 0x00, 0x3e, 0x76 ; 1 
    db 0x00, 0x3d, 0x23 ; 2 
    db 0x00, 0x44, 0x6a ; 3 
    db 0x00, 0x46, 0x01 ; 4 
    db 0x00, 0x4a, 0x46 ; 5 
    db 0x00, 0x4d, 0x34 ; 6 
    db 0x00, 0x4c, 0x08 ; 7 
    db 0x00, 0x35, 0xf1 ; 8 
    db 0x00, 0x47, 0xb3 ; 9 
    db 0x00, 0x44, 0x54 ; 10 
    db 0x00, 0x4e, 0x22 ; 11 
    db 0x00, 0x4d, 0x51 ; 12 
    db 0x00, 0x4f, 0xff ; 13 
    db 0x00, 0x57, 0x6a ; 14 
    db 0x00, 0x54, 0x08 ; 15 
    db 0x00, 0x5b, 0x83 ; 16 
    db 0x00, 0x65, 0x0e ; 17 
    db 0x00, 0x4b, 0x4f ; 18 
    db 0x00, 0x5b, 0x63 ; 19 
    db 0x00, 0x4c, 0x80 ; 20 
    db 0x00, 0x43, 0x02 ; 21 30
    db 0x00, 0x48, 0xe5 ; 22 40
    db 0x00, 0x47, 0xd5 ; 23 50
    db 0x00, 0x56, 0x8a ; 24 60
    db 0x00, 0x57, 0xb9 ; 25 70
    db 0x00, 0x41, 0xa0 ; 26 80
    db 0x00, 0x4d, 0x50 ; 27 90
    db 0x00, 0x50, 0x02 ; 28 hundred
    db 0x00, 0x76, 0x13 ; 29 The temp is
    db 0x00, 0x7e, 0x71 ; 30 Degrees celsius
    db 0x00, 0x6c, 0x40 ; 31 fucking gay
    db 0x00, 0x41, 0xde ; 32 



; The sound and its length from the two tables above is passed in the accumulator.
Play_Sound_Using_Index:
	setb SOUND ; Turn speaker on
	clr TMOD20 ; Stop the CCU from playing previous request
	setb FLASH_CE
	
	; There are three bytes per row in our tables, so multiply index by three
	mov b, #3
	mul ab
	mov R0, a ; Make a copy of the index*3
	
	clr FLASH_CE ; Enable SPI Flash
	mov a, #READ_BYTES
	lcall Send_SPI
	; Set the initial position in memory of where to start playing
	mov dptr, #sound_index
	mov a, R0
	movc a, @a+dptr
	lcall Send_SPI
	inc dptr
	mov a, R0
	movc a, @a+dptr
	lcall Send_SPI
	inc dptr
	mov a, R0
	movc a, @a+dptr
	lcall Send_SPI
	; Now set how many bytes to play
	mov dptr, #Size_Length
	mov a, R0
	movc a, @a+dptr
	mov w+2, a
	inc dptr
	mov a, R0
	movc a, @a+dptr
	mov w+1, a
	inc dptr
	mov a, R0
	movc a, @a+dptr
	mov w+0, a
	
	mov a, #0x00 ; Request first byte to send to DAC
	lcall Send_SPI
	
	setb TMOD20 ; Start playback by enabling CCU timer

	ret


;---------------------------------------------------------------------------------;
; This is the FSM that plays minutes and seconds after the STOP button is pressed ;
; The state diagram of this FSM is available as 'Stop_Watch_FSM.pdf'              ;
;---------------------------------------------------------------------------------;
FSM_Start:
	jb Sec5, state_3 
	;mov FSMState, #0
	;cjne a, #0, State_3
	;clr Sec5
	ret
State_3:
	mov a, #29 ;"Temperature currently:x"
	lcall Play_Sound_Using_Index
	mov FSMState, #3
State_3D:
	mov a, FSMState
	cjne a, #3, State_4
	jb TMOD20, State_3D
	mov FSMState, #4
	sjmp State_3D
	;hundreds place check
State_4:
	mov a, BCD+1
	cjne a, #0, State_5
	ljmp State_7
	;play hundreds place
State_5: 
	mov a, BCD+1
	lcall Play_Sound_Using_Index
	mov FSMState, #5
State_5D:
	mov a,FSMState
	cjne a, #5, State_6
	jb TMOD20, State_5D
	mov FSMState, #6
	sjmp State_5D
State_6:
	mov a,#28 ;100 deg call
	lcall Play_Sound_Using_Index
	mov FSMState, #6
State_6D:
	mov a, FSMState
	cjne a, #6, State_7
	jb TMOD20, State_6D
	mov FSMState, #7
	sjmp State_6D
State_7:
	mov a, BCD
	swap a
	anl a, #0x0F
	cjne a, #1, State_9
State_8:
	mov a, BCD
	lcall Play_Sound_Using_Index
	mov FSMState, #8
State_8D:
	mov a, FSMState
	cjne a, #8, State_12
	jb TMOD20, State_8D
	mov FSMState, #9
	sjmp State_8D	
State_9:
	mov a, BCD
	swap a
	anl a, #0x0F
	cjne a, #0, State_11
State_10:
	mov a, BCD
	anl a, #0x0F
	lcall Play_Sound_Using_Index	
	mov FSMState, #10
State_10D:
	mov a, FSMState
	cjne a, #10, State_12
	jb TMOD20, State_10D
	mov FSMState, #12
	sjmp State_10D
State_11:
	mov a, BCD
	swap a
	anl a, #0x0F
	add a, #18
	lcall Play_Sound_Using_Index
	mov FSMState, #11
State_11D:
	mov a, FSMState
	cjne a, #11, State_13
	jb TMOD20, State_11D
	mov FSMState, #12
	sjmp State_11D
State_12:
	mov a, #30 ;Celsius call
	lcall Play_Sound_Using_Index
	mov FSMState, #12
State_12D:
	mov a, FSMState
	cjne a, #12, DONE
	jb TMOD20, State_12D
	mov FSMState, #0
	sjmp State_12D
State_13:
	mov a, BCD
	anl a, #0x0F
	cjne a, #0, State_10
	ljmp State_12
DONE:
	clr Sec5
	mov FSMState, #0
	ret
; End of FMS that plays minutes and seconds

Line1: db 'Stop watch', 0
Line2: db '00:00', 0
	
;---------------------------------;
; Main program. Includes hardware ;
; initialization and 'forever'    ;
; loop.                           ;
;---------------------------------;
MainProgram:
    mov SP, #0x7F
    
    lcall Ports_Init ; Default all pins as bidirectional I/O. See Table 42.
    lcall LCD_4BIT
    lcall Double_Clk
	lcall InitDAC1 ; Call after 'Ports_Init'
	lcall CCU_Init
	lcall Init_SPI
	lcall Timer1_Init
	
	clr TR1 ; Stop timer 1
	
	clr TMOD20 ; Stop CCU timer
	setb EA ; Enable global interrupts.
	

	
	clr SOUND ; Turn speaker off
	mov FSMState, #0
	setb Sec5
	; Initialize variables
	clr T2S_FSM_Start
	mov T2S_FSM_state, #0
	mov minutes, #0
	mov seconds, #0

	Set_Cursor(1, 1)
    Send_Constant_String(#Line1)
	Set_Cursor(2, 1)
    Send_Constant_String(#Line2)
    
    mov bcd, #0b10010000
	mov bcd+1, #1
	mov bcd+2, #0
;	mov bcd, #10    
 ;   mov a, BCD
;	lcall Play_Sound_Using_Index
;	jb TMOD20, $ ; Wait for sound to finish playing

    
; Test that we can play any sound from the index
	;mov a, #26
	;lcall Play_Sound_Using_Index
	;jb TMOD20, $ ; Wait for sound to finish playing

; Test that we can play any minutes:seconds combination properly (although for 01:01 it says 'one minutes one seconds')
	;mov minutes, #25
	;mov seconds, #37
	;setb T2S_FSM_Start
	
forever_loop:
	
	lcall FSM_Start ; Run the state machine that plays minutes:seconds
forever_loop2:
	
	
	jnb seconds_flag, check_START_Push_Button
	; One second has passed, refresh the LCD with new time
	clr seconds_flag
	Set_Cursor(2, 1)
	mov a, minutes
    lcall LCD_number
	Set_Cursor(2, 4)
	mov a, seconds
    lcall LCD_number
	
check_START_Push_Button:
	jb START, check_STOP_Push_Button
	Wait_Milli_Seconds(#50) ; debounce
	jb START, check_STOP_Push_Button
	jnb START, $
	setb TR1 ; Start Timer 1.  The ISR for timer 1 increments minutes and seconds when running.
	sjmp check_DONE
	
check_STOP_Push_Button:
    jb STOP, check_CLEAR_Push_Button
	Wait_Milli_Seconds(#50) ; debounce
	jb STOP, check_CLEAR_Push_Button
	jnb STOP, $
	clr TR1 ; Stop timer 1.
	 ; This plays the current minutes:seconds by making the state machine get out of state zero.
	sjmp check_DONE
	
check_CLEAR_Push_Button:
    jb CLEAR, check_DONE
	Wait_Milli_Seconds(#50) ; debounce
	jb CLEAR, check_DONE
	jnb CLEAR, $
    clr TR1 ; Stop timer 1.
    mov minutes, #0
    mov seconds, #0
    setb seconds_flag ; Force update of LCD with new time, in this case 00:00
	sjmp check_DONE
	
check_DONE:	
	ljmp forever_loop

END
