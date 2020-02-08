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


CLK           EQU 33333333 ; Microcontroller system crystal frequency in Hz
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))
PEAK_TEMPERATURE EQU 260

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


dseg at 0x30
Count1ms: ds 2; Used to determine when half a second has passed
ctemp: ds 2   ; current temperature
rtemp: ds 2   ; reflow  temperature
stemp: ds 2   ; soak temperature
ctime: ds 2   ; current time
stime: ds 2   ; soak time
rtime: ds 2   ; reflow time

adjust_state: ds 1
displayed_state: ds 1

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
Key1_flag: dbit 1
Key2_flag: dbit 1
Key3_flag: dbit 1

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
	mov adjust_state, #0
	mov displayed_state, #0
    mov ctemp #0
    mov rtemp, #217   ; minimum reflow  temperature
	mov stemp, #130   ; minimum soak temperature
	mov ctime, #0   ; current time
	mov stime, #60  ; soak time
	mov rtime, #45   ; reflow time   
	sjmp default_state
	; After initialization the program stays in this 'forever' loop
	lcall Default_state ;starts off in default display screen until button pressed

loop: 
	;
	jnb sw_start_stop, param_adjust
	ljmp Oven_Control
	
	
        
Default_state:
	;set power to 0 (turn off oven)
        jb button_state, Default_state; if the 'button_updown' button is not pressed skip
	Wait_Milli_Seconds(#50)	; Debounce delay.  This macro is also in 'LCD_4bit.inc'
	jb button_state, Default_state  ; if the 'BOOT' button is not pressed skip (loops repeatedly without increment while button pressed)
	jnb button_state, $
	jb sw_start_stop, param_adjust ;if switch down, adjust parameters	
        ljmp Displaymain
      
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
    mov a, stemp
    add a, #0x01
    da a
    cjne a, #0x170, inc_soak_time_1
    mov a, #0x130
    mov stime, a
    ljmp soak_temp_done
inc_soak_temp_1:
    ljmp soak_temp_done
    
dec_soak_temp:
    mov a, stemp
    dec a, #0x01
    da a
    cjne a, #0x130,dec_soak_time_1
    mov a, #0x170
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
    cjne a, #0x90, inc_soak_time_1
    mov a, #0x60
    mov stime, a
    ljmp soak_time_done
inc_soak_time_1:
    ljmp soak_time_done
    
dec_soak_time:
    mov a, stime
    dec a, #0x01
    da a
    cjne a, #0x60,dec_soak_time_1
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
    cjne a, #0x230, inc_soak_time_1
    mov a, #0x219
    mov rtemp, a
    ljmp reflow_temp_done
inc_reflow_temp_1:
    ljmp reflow_temp_done
    
dec_reflow_temp:
    mov a, rtemp
    dec a, #0x01
    da a
    cjne a, #0x219, dec_reflow_temp_1
    mov a, #0x230
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

state1: 	;Ramp to Soak

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
    
      
      

