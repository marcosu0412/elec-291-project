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


; Reset vector
org 0x0000
    ljmp main

; Timer/Counter 2 overflow interrupt vector
org 0x002B
	ljmp Timer2_ISR
	
org 0x005b ; CCU interrupt vector.  Used in this code to replay the wave file.
	ljmp CCU_ISR

CLK           EQU 14746000 ; Microcontroller system crystal frequency in Hz
TIMER2_RATE   EQU 1000     ; 1000Hz, for a timer tick of 1ms
TIMER2_RELOAD EQU ((65536-(CLK/(12*TIMER2_RATE))))
PEAK_TEMPERATURE EQU 260
XTAL EQU 7373000
BAUD EQU 115200
BRVAL EQU ((XTAL/BAUD)-16)

;---------------------------------;
; LCD Pins			  ;
;---------------------------------;
LCD_RS equ P0.7
LCD_RW equ P3.0
LCD_E  equ P3.1
LCD_D4 equ P2.0
LCD_D5 equ P2.1
LCD_D6 equ P2.2
LCD_D7 equ P2.3

;---------------------------------;
; Button/Switch Pins		  ;
;---------------------------------;
sw_start_stop equ P0.0
sw_updown     equ P0.3
button_updown equ P0.4
button_state  equ P0.5
button_reset  equ P2.6
;---------------------------------;
; Temperature and Power		  ;
;---------------------------------;
TEMP_IN 	equ P2.4
POWER_OUT 	equ P2.7

;---------------------------------;
; Variable Names		  ;
;---------------------------------;
dseg at 0x30
Count1ms: ds 2; Used to determine when half a second has passed
ctemp: ds 4   ; current temperature
ctime: ds 4   ; current time

rtemp:			 ds 2   ; reflow  temperature
stemp:			 ds 2   ; soak temperature
rtime:			 ds 2   ; reflow time
stime:		   	 ds 2   ; soak time
power_pulse:     ds 1 ; power pulse
pwm:             ds 1 ; pwm for power
tt:              ds 1 ; temporary variable to hold stime 

adjust_state: ds 1
oven_state: ds 1

x: ds 4 ;for use in math32
y: ds 4
bcd: ds 5

bseg
mf: dbit 1

setsoaktime:
DB 'Soak Time', 0

setsoaktemperature:
DB 'Soak Temp', 0

setreflowtemperature:
DB 'Reflow Temp', 0

setreflowtime:
DB 'Reflow Time', 0

displaystate1:
DB 'Preheat ', 0

displaystate2:
DB 'Soaking ', 0

displaystate3:
DB 'Ramping ', 0

displaystate4:
DB 'Reflow  ', 0

displaystate5:
DB 'Cooling ', 0

displayabort:
DB 'Aborting...', 0


;---------------------------------;
; Flags				  ;
;---------------------------------;
bseg
; For each pushbutton we have a flag.  The corresponding FSM will set this
; flags to one when a valid press of the pushbutton is detected.
soak_time_flag:         dbit 1
soak_temp_flag:         dbit 1
reflow_time_flag:       dbit 1
reflow_temp_flag:       dbit 1
abort_flag: 		    dbit 1

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
    clr TR2  ; stop timer 2 
	ret

Timer2_start:
	setb TR2 ; start timer 2
	ret
	
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
	setb P2.6 ; To check the interrupt rate with oscilloscope.
	
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

CCU_ISR_Done:	
	pop psw
	pop acc
	clr P2.6
	reti

;---------------------------------;
; ISR for timer 2.  Runs evere ms ;
;---------------------------------;
Timer2_ISR:
	clr TF2  ; Timer 2 doesn't clear TF2 automatically. Do it in ISR
		     ; The two registers used in the ISR must be saved in the stack
	push acc
	push psw
	
	
	
	inc power_pulse
	clr c
	mov a, power_pulse
	subb a, pwm
	mov POWER_OUT, c
	
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
	
;---------------------------------;
; Routine to initialize the ISR   ;
; for timer 0                     ;
;---------------------------------;
Timer0_Init:
	mov a, TMOD
	anl a, #0xf0 ; Clear the bits for timer 0
	orl a, #0x01 ; Configure timer 0 as 16-timer
	mov TMOD, a
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	; Enable the timer and interrupts
        setb ET0  ; Enable timer 0 interrupt
        setb TR0  ; Start timer 0
	ret

;---------------------------------;
; ISR for timer 0.  Set to execute;
; every 1/4096Hz to generate a    ;
; 2048 Hz square wave at pin P3.7 ;
;---------------------------------;
Timer0_ISR:
	mov TH0, #high(TIMER0_RELOAD)
	mov TL0, #low(TIMER0_RELOAD)
	
        
	
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

SendTemp:
	mov dptr, #HexAscii 
	
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
	mov tt, #0x00
	; After initialization the program stays in this 'forever' loop
	lcall Default_state ;starts off in default display screen until button pressed

loop:   
        lcall check_abort
        jb abort_flag, abort
	    lcall accumulate_loop_start
		clr a 
	    mov a, oven_state
		cjne a, #0, checkmain1
		ljmp state1 ; jump to ramp to soak
checkmain1:	
        cjne a, #1, checkmain2
		clr a
		ljmp state2 ; jump to soak
		
checkmain2:	
        cjne a, #2, checkmain3
		clr a 
		ljmp state3 ; jump to ramp to peak
		
checkmain3:	
        cjne a, #3, checkmain4
		clr a 
		ljmp state4 ; jump to reflow
		
checkmain4:	
        cjne a, #4, abort
		clr a 
		ljmp state5 ; jump to cooling 

check_abort:
        mov a, ctemp+1
        cjne a, #0x02, abort_return
		mov a, ctemp 
		cjne a, #0x50, abort_return
		setb abort_flag
		ret 
abort_return:
        ret       


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
	setb TF2; Start the timer 
    ljmp loop

param_adjust:
    jnb     sw_start_stop, default_state
	mov a, adjust_state
	cjne 	a, #0, check1 ;jump if bit set (switch down)
	ljmp 	soak_temp
check1:
    mov a, adjust_state
	cjne a, #1, check2
	clr a 
	ljmp soak_time
check2:
	cjne a, #2, check3
	clr a 
	ljmp reflow_temp
    
check3:
  	ljmp reflow_time
    ret  
    
;in each of these, change display and read button_updown to adjust
;also read button_state to inc adjust_state
soak_temp:
    lcall Display_soak_temperature
    jb button_updown, param_adjust ;check if button_down is pressed. 
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
    mov stemp, a
    ljmp soak_temp_done
inc_soak_temp_1:
    ljmp soak_temp_done
    
dec_soak_temp:
    mov a, stemp
    subb a, #0x01
    da a
    cjne a, #0x29,dec_soak_temp_1
    mov a, #0x70
    mov stemp, a
   	ljmp soak_temp_done
dec_soak_temp_1:
    	ljmp soak_temp_done
    
soak_temp_done:    
	jb button_state, soak_temp
	Wait_Milli_Seconds(#50)	
	jb button_state, soak_temp 
	jnb button_state, $
    
	inc adjust_state
	ljmp param_adjust
     


soak_time:
    lcall Display_soak_time
    jb button_updown, param_adjust ; check if button_down is pressed. 
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
    dec a 
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
    ljmp param_state

reflow_temp:
    lcall Display_reflow_temperature
    jb button_updown, param_adjust ; check if button_down is pressed. 
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
    dec a 
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
    ljmp param_adjust

reflow_time:
    lcall display_reflow
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
	ljmp param_adjust
 
Oven_Control:
;in each state, set power (0,40,100)
;set timer for soak and peak states (count down every second, set flag at 0, transition state if flag set)
;measure temperature, set flag when predefined soak/ramp temperature reached, transition state 


state1: 	;Ramp to Soak
	Set_Cursor(1,1)
	Send_Constant_String(#displaystate1)
    mov pwm, #255 ; 100% power
	mov a, stemp ; a equals setting temp lower bit
    clr c 
	subb a, ctemp
	jc state1_2
    ljmp loop 
state1_2:
    mov a, stemp+1
    clr c 
	subb a, ctemp+1
	jz done_ramp_to_soak
    ljmp loop
done_ramp_to_soak:
    inc oven_state
	mov tt, stime
	ljmp loop
        

state2: 	;Soak
	Set_Cursor(1,1)
	Send_Constant_String(#displaystate2)
	mov pwm, #102 ; 40% power 
	dec tt
	mov a, tt 
	cjne a, #0, loop
    ljmp state2_done
state2_done:
    inc oven_state
	clr tt 
	ljmp loop

state3:		;Ramp to Peak
	Set_Cursor(1,1)
	Send_Constant_String(#displaystate3)
	mov pwm, #255 ; 100% power
	mov a, rtemp ; a equals setting temp
	clr c
	subb a, ctemp  ; compare setting temp and ctemp
	jc state3_2     
	ljmp loop 
state3_2:
    mov a, rtemp+1
	clr c
	subb a, ctemp+1
	jz done_ramp_to_reflow
    ljmp loop
done_ramp_to_reflow:
    inc state
	mov tt, rtime 
	ljmp loop

state4:		;reflow
	Set_Cursor(1,1)
	Send_Constant_String(#displaystate4)
    mov pwm, #((255*20)/100) ; 20% of power
    dec tt
	mov a, tt 
	cjne a, #0, loop
	ljmp state4_done
state4_done:
    inc oven_state
	clr tt 
	ljmp loop

state5:		;Cooling   
	Set_Cursor(1,1)
	Send_Constant_String(#displaystate5)
	mov pwm, #0 ; 0% power
	mov a, ctemp
	clr c
    subb a,#0x60
	jc state5_2
	ljmp loop
state5_2:
    mov a, ctemp+1
	jz done_cooling
	ljmp loop 
done_cooling:
    inc state 
	ljmp loop 	

abort:
    Set_Cursor(1,1)
	Send_Constant_String(#displayabort)
    mov pwm, #0
	



Display_oven_time:
	Set_Cursor(2,1)
	Display_BCD(ctime+2)
	Set_Cursor(2,2)
	Display_BCD(ctime+1)
	Set_Cursor(2,3)
	Display_BCD(ctime+0)
	Set_Cursor(2,4)
	Display_BCD(#'s')
	ret
	
Display_oven_temp:
	Set_Cursor(1,10)
	Display_BCD(ctemp+2)
	Set_Cursor(1,11)
	Display_BCD(ctemp+1)
	Set_Cursor(1,12)
	Display_BCD(ctemp+0)
	Set_Cursor(1,13)
	Display_BCD(#223) ;degrees character
	Set_Cursor(1,14)
	Display_BCD(#'C')
	ret

Display_soak_time:
    Set_Cursor(1,1)
	Send_Constant_String(#setsoaktime)
	Set_Cursor(2,1)
	Display_BCD(stime)
	ret 

Display_soak_temperature:
    Set_Cursor(1,1)
	Send_Constant_String(#setsoaktemperature)
	Set_Cursor(2,1)
	Display_BCD(stemp)
	ret

Display_reflow_temperature:
    Set_Cursor(1,1)
	Send_Constant_String(#setreflowtemperature)    
	Set_Cursor(2,1)
	Display_BCD(rtemp)
	ret

Display_reflow_time:
    Set_Cursor(1,1)
	Send_Constant_String(#setreflowtime) 
	Set_Cursor(2,1)   
	Display_BCD(rtime)
    ret
    
   
;ADDING AUDIO
   
   
      
     
end
      

