; Non_Blocking_FSM_example.asm:  Four FSMs are run in the forever loop.
; Three FSMs are used to detect (with debounce) when either KEY1, KEY2, or
; KEY3 are pressed.  The fourth FSM keeps a counter (Count3) that is incremented
; every second.  When KEY1 is detected the program increments/decrements Count1,
; depending on the position of SW0. When KEY2 is detected the program
; increments/decrements Count2, also base on the position of SW0.  When KEY3
; is detected, the program resets Count3 to zero.  
;
$NOLIST
$MODDE1SOC
$LIST

$NOLIST
$include(LCD_4bit.inc)
$LIST


$NOLIST
$include(math32.inc)
$LIST


CLK           EQU 14746000 ; Microcontroller system crystal frequency in Hz
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))
PEAK_TEMPERATURE EQU 260
XTAL EQU 7373000
BAUD EQU 115200
BRVAL EQU ((XTAL/BAUD)-16)

LCD_RS equ P0.7
LCD_RW equ P3.0
LCD_E  equ P3.1
LCD_D4 equ P2.0
LCD_D5 equ P2.1
LCD_D6 equ P2.2
LCD_D7 equ P2.3

sw_start_stop equ P0.0
sw_updown     equ P0.3
button_updown equ P0.4
button_state  equ P0.5



;change ports later when configuration is figured out
TEMP_IN 	equ P2.4
POWER_OUT 	equ P2.5


dseg at 0x30
Count1ms: ds 2; Used to determine when half a second has passed
ctemp: ds 4   ; current temperature
ctime: ds 4   ; current time

rtemp: ds 2   ; reflow  temperature
stemp: ds 2   ; soak temperature
rtime: ds 2   ; reflow time
stime: ds 2   ; soak time

adjust_state: ds 1
displayed_state: ds 1

x: ds 4 ;for use in math32
y: ds 4
bcd: ds 5

bseg
mf: dbit 1

setsoaktime:
DB 'Soak Time', 0

setsoaktemperature:
DB 'Soak Temperature', 0

setreflowtemperature:
DB 'Reflow Temperature', 0

setreflowtime:
DB 'Reflow Time', 0

; Reset vector
org 0x0000
    ljmp main

; Timer/Counter 2 overflow interrupt vector
org 0x002B
	ljmp Timer2_ISR


bseg
; For each pushbutton we have a flag.  The corresponding FSM will set this
; flags to one when a valid press of the pushbutton is detected.
soak_time_flag:         dbit 1
soak_temp_flag:         dbit 1
reflow_time_flag:       dbit 1
reflow_temp_flag:       dbit 1
abort_flag 		dbit 1

cseg
;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 2                     ;
;---------------------------------;
Timer2_Init:
	mov T2CON, #0 ; Stop timer/counter.  Autoreload mode.
	mov TH2, #high(TIMER2_RELOAD)
	mov TL2, #low(TIMER2_RELOAD)
	; Set the reload value
	mov RCAP2H, #high(TIMER2_RELOAD)
	mov RCAP2L, #low(TIMER2_RELOAD)
	; Enable the timer and interrupts
    setb ET2  ; Enable timer 2 interrupt
     clr TR2  ; Enable timer 2 
	ret

Timer2_start:
	setb TR2 ; start timer 2
	ret

;---------------------------------;
; ISR for timer 2.  Runs evere ms ;
;---------------------------------;
Timer2_ISR:
	clr TF2  ; Timer 2 doesn't clear TF2 automatically. Do it in ISR
		; The two registers used in the ISR must be saved in the stack
	push acc
	push psw
	
	; Increment the 16-bit one mili second counter
	inc Count1ms+0    ; Increment the low 8-bits first
	mov a, Count1ms+0 ; If the low 8-bits overflow, then increment high 8-bits
	jnz Inc_Done
	inc Count1ms+1

Inc_Done:
	; Check if full second has passed
	mov a, Count1ms+0
	cjne a, #low(1000), Timer2_ISR_done ; Warning: this instruction changes the carry flag!
	mov a, Count1ms+1
	cjne a, #high(1000), Timer2_ISR_done
	
	inc ctime

	clr a
	mov Count1ms+0, a
	mov Count1ms+1, a
	; Increment the current time counter

Timer2_ISR_done:
	pop psw
	pop acc
	reti

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
	jnb	acc.3,InitADC
	ret

; Look-up table for the 7-seg displays. (Segments are turn on with zero) 
T_7seg:
    DB 40H, 79H, 24H, 30H, 19H, 12H, 02H, 78H, 00H, 10H

; Displays a BCD number pased in R0 in HEX1-HEX0
Display_BCD_7_Seg_HEX10:
	mov dptr, #T_7seg

	mov a, R0
	swap a
	anl a, #0FH
	movc a, @a+dptr
	mov HEX1, a
	
	mov a, R0
	anl a, #0FH
	movc a, @a+dptr
	mov HEX0, a
	
	ret

; Displays a BCD number pased in R0 in HEX3-HEX2
Display_BCD_7_Seg_HEX32:
	mov dptr, #T_7seg

	mov a, R0
	swap a
	anl a, #0FH
	movc a, @a+dptr
	mov HEX3, a
	
	mov a, R0
	anl a, #0FH
	movc a, @a+dptr
	mov HEX2, a
	
	ret

; Displays a BCD number pased in R0 in HEX5-HEX4
Display_BCD_7_Seg_HEX54:
	mov dptr, #T_7seg

	mov a, R0
	swap a
	anl a, #0FH
	movc a, @a+dptr
	mov HEX5, a
	
	mov a, R0
	anl a, #0FH
	movc a, @a+dptr
	mov HEX4, a
	
	ret

; The 8-bit hex number passed in the accumulator is converted to
; BCD and stored in [R1, R0]
Hex_to_bcd_8bit:
	mov b, #100
	div ab
	mov R1, a   ; After dividing, a has the 100s
	mov a, b    ; Remainder is in register b
	mov b, #10
	div ab ; The tens are stored in a, the units are stored in b 
	swap a
	anl a, #0xf0
	orl a, b
	mov R0, a
	ret

;---------------------------------;
; Main program. Includes hardware ;
; initialization and 'forever'    ;
; loop.                           ;
;---------------------------------;
main:
	; Initialization of hardware
	mov SP, #0x7F
	lcall Timer2_Init
	; Turn off all the LEDs
	; mov LEDRA, #0 ; LEDRA is bit addressable
	; mov LEDRB, #0 ; LEDRB is NOT bit addresable
	setb EA   ; Enable Global interrupts
    
    	; Initialize variables
	clr abort_flag
	mov adjust_state, #0
	mov displayed_state, #0
	mov ctemp, #0
   	mov rtemp, #0x17   ; minimum reflow  temperature
	mov rtemp+1, #0x02;
	mov stemp, #0x30   ; minimum soak temperature
	mov stemp+1, #0x01
	mov ctime, #0x00   ; current time
	mov ctime+1, #0x00
	mov stime, #0x60  ; soak time
	mov stime+1, #0x00
	mov rtime, #0x45   ; reflow time   
	mov rtime+1, #0x00
	; After initialization the program stays in this 'forever' loop
	lcall Default_state ;starts off in default display screen until button pressed

loop: 
	lcall accumulate_loop_start
	l

accumulate_loop_start:
        ; Take 256 (4^4) consecutive measurements of ADC0 channel 0 at about 10 us intervals and accumulate in x
	Load_x(0)
    	mov x+0, AD0DAT0
	mov R7, #255
    	lcall Wait10us
accumulate_loop:
    	mov y+0, AD0DAT0
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
	
	lcall hex2bcd
	mov ctemp+0, x+0 	;store calculated temperature into x
	mov ctemp+1, x+1
	mov ctemp+2, x+2
	mov ctemp+3, x+3
	lcall SendTemp ; Send to PUTTy, with 2 decimal digits to show that it actually works
	lcall Wait1S

	ret
	
	
	
        
Default_state:
	;set power to 0 (turn off oven)
    	jb button_state, Default_state; if the 'button_updown' button is not pressed skip
	Wait_Milli_Seconds(#50)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb button_state, Default_state  ; if the 'BOOT' button is not pressed skip (loops repeatedly without increment while button pressed)
	jnb button_state, $
	jb sw_start_stop, param_adjust ;if switch down, adjust parameters	
    	ljmp loop
      
param_adjust:
    	jb button_state, param_adjust 
	Wait_Milli_Seconds(#50)	
	jb button_state, param_adjust 
	jnb button_state, $
	cjne 	adjust_state, #0, check1 ;jump if bit set (switch down)
	ljmp 	soak_temp
check1:
	cjne adjust_state, #1, check2
	ljmp soak_time
check2:
	cjne adjust_state, #2, check3
	ljmp reflow_temp
    
check3:
  	ljmp reflow_time
        ret     
    
;in each of these, change display and read button_updown to adjust
;also read button_state to inc adjust_state
soak_temp:
    	jb button_updown, param_adjust //check if button_down is pressed. 
	Wait_Milli_Seconds(#50)	
	jb button_updown, param_adjust
	jnb button_updown, $
    	jb sw_updown, dec_soak_temp
	
inc_soak_temp:
   	mov a, stemp+0
   	add a, #0x01
    	da a
    	cjne a, #0x71, inc_soak_temp_1
    	mov a, #0x30
    	mov stime, a
    	ljmp soak_temp_done
inc_soak_temp_1:
    	ljmp soak_temp_done
    
dec_soak_temp:
    	mov a, stemp
    	dec a, #0x01
    	da a
    	cjne a, #0x29,dec_soak_temp_1
    	mov a, #0x70
    	mov stime, a
   	ljmp soak_temp_done
dec_soak_temp_1:
    	ljmp soak_temp_done
    
soak_temp_done:    
	jb button_state, soak_temp
	Wait_Milli_Seconds(#50)	
	jb button_state, soak_temp 
	jnb button_state, $
    
	inc adjust_state
	ljmp loop
     


soak_time:
    jb button_updown, param_adjust //check if button_down is pressed. 
    Wait_Milli_Seconds(#50)	
    jb button_updown, param_adjust
    jnb button_updown, $
    jb sw_updown, dec_soak_time
    
inc_soak_time:
    mov a, stime
    add a, #0x01
    da a
    cjne a, #0x91, inc_soak_time_1
    mov a, #0x60
    mov stime, a
    ljmp soak_time_done
inc_soak_time_1:
    ljmp soak_time_done
    
dec_soak_time:
    mov a, stime
    dec a, #0x01
    da a
    cjne a, #0x59,dec_soak_time_1
    mov a, #0x90
    mov stime, a
    ljmp soak_temp_done
dec_soak_time_1:
    ljmp soak_time_done 
    
soak_time_done:
    jb button_state, soak_time
    Wait_Milli_Seconds(#50)	
    jb button_state, soak_time
    jnb button_state, $
    
    inc adjust_state
    ljmp loop

reflow_temp:
    jb button_updown, param_adjust //check if button_down is pressed. 
    Wait_Milli_Seconds(#50)	
    jb button_updown, param_adjust
    jnb button_updown, $
    jb sw_updown, dec_reflow_temp
	
inc_reflow_temp:
    mov a, rtemp
    add a, #0x01
    da a
    cjne a, #0x31, inc_reflow_temp_1
    mov a, #0x19
    mov rtemp, a
    ljmp reflow_temp_done
inc_reflow_temp_1:
    ljmp reflow_temp_done
    
dec_reflow_temp:
    mov a, rtemp
    dec a, #0x01
    da a
    cjne a, #0x18, dec_reflow_temp_1
    mov a, #0x30
    mov rtemp, a
    ljmp reflow_temp_done
dec_reflow_temp_1:
    ljmp reflow_temp_done 
    
reflow_temp_done:
    jb button_state, reflow_temp
    Wait_Milli_Seconds(#50)	
    jb button_state, reflow_temp
    jnb button_state, $
    inc adjust_state
    ljmp loop 

reflow_time:
    jb button_updown, param_adjust
    Wait_Milli_Seconds(#50)
    jb button_updown, param_adjust
    jnb button_updown, $
    jb sw_updown, dec_reflow_time
	
inc_reflow_time:
	mov a, rtime
	add a, #0x01
	da a
	cjne a, #0x60, inc_reflow_time_1
	mov a, #0x30
	mov rtime, a
	ljmp reflow_time_done
inc_reflow_time_1:
	ljmp reflow_time_done
	
dec_reflow_time:
	mov a, rtime
	dec a
	da a
	cjne a, #0x30, dec_reflow_time_1
	mov a, #0x60
	mov rtemp, a
	ljmp reflow_time_done
dec_reflow_time_1:
	ljmp reflow_time_done
	
reflow_time_done:
	jb button_state, reflow_temp
	Wait_Milli_seconds(#50)
	jb button_state, reflow_temp
	jnb button_state, $
	mov adjust_state, #0
	ljmp loop
 
Oven_Control:
;in each state, set power (0,20,100)
;set timer for soak and peak states (count down every second, set flag at 0, transition state if flag set)
;measure temperature, set flag when predefined soak/ramp temperature reached, transition state 


state1: 	;Ramp to Soak
	mov 

state2: 	;Soak

state3:		;Ramp to Peak

state4:		;Peak

state5:		;Cooling
    

Display_soak_time:
    Set_Cursor(1,1)
	Send_Constant_String(#setsoaktime)
	Set_Cursor(2,1)
	Display_BCD(stime)
	ljmp soak_time

Display_soak_temperature:
    Set_Cursor(1,1)
	Send_Constant_String(#setsoaktemperature)
	Set_Cursor(2,1)
	Display_BCD(stemp)
	ljmp soak_temp

Display_reflow_temperature:
    Set_Cursor(1,1)
	Send_Constant_String(#setreflowtemperature)    
	Set_Cursor(2,1)
	Display_BCD(rtemp)
	ljmp reflow_temp

Display_reflow_time:
    Set_Cursor(1,1)
	Send_Constant_String(#setreflowtime) 
	Set_Cursor(2,1)   
	Display_BCD(rtime)
	ljmp reflow_time
    
      
      

