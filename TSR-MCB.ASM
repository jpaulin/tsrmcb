MODEL SMALL
CODESEG
ORG 100H

;
; This is a assembly source code of the TSR-MCB program.
; It is a terminate-stay-resident program which operates under
; MS-DOS. It can be called by hitting the hotkey, default 'F12'.
; Needs ITS to function. ITS is a general TSR service platform.
; Outputs a crude ASCII-based window, where the information can
; be scrolled using arrow keys. Sometimes jams the keyboard weirdly,
; especially if run under Windows.
; TSR-MCB is used to inspect the memory control blocks of MS-DOS.
;
;------------------------------------------------------------------------
; Date:       Note:
; -----       -----
; 11.12.1993  Keyboard reading now using INT 16h instead of port 60h
; 24.01.1994  Added support to varying screen sizes
; 17.06.1994  Added FREEMEM
; 30.08.2001  Investigating the source code once again and figuring out
; 		      how time passes :-) Putting the source code under source
; 		      code museum at my web space on odyssey.tky.hut.fi 
;----------------------------------------------------------------------------

;----------------------------------------------------------------------------
; MACROs and equ -definitions for convenience
;----------------------------------------------------------------------------

des        equ 0
hex        equ 1
true       equ 1
false      equ 0
maxMCB     equ 128          ; maximum amount of MCBs to handle
stradjust  equ -2           ; adjustion for PutString (in horizontal)
charBorder equ 'Û'          ; pretty obvious, isn't it?!?

colorBack  equ 00010000b
colorHead  equ colorBack+14
colorData  equ colorBack+10
colorNdat  equ colorBack+7
colorInfo  equ colorBack+11
colorSpec  equ colorBack+12
colorBord  equ colorBack+9
colorAvail equ colorBack+3
colorVers  equ 4*16+15

print macro string
        push ax dx
        mov ah,9
        lea dx,[string]
        int 21h
        pop dx ax
endm

retrace macro
        local rj1,rj2
        push ax dx
        mov dx,3DAh
rj1:    in al,dx
        test al,8
        jnz rj1
rj2:    in al,dx
        test al,8
        jz rj2
        pop dx ax
endm

Start:          jmp Real_Start

;----------------------------------------------------------------------------
; þ GLOBAL VARIABLES |
;----------------------------------------------------------------------------

str_vers        db 'v1.202',0
first_mcb       dw ?         ; this is set during installation
mcbSegments     dw maxMCB dup(?)    ; here we store those addresses
mcbCount        db ?                ; total numbers of MCBs in memory
mcbBroken       db ?                ; is the chain broken? (true or false)
memFreeP        dw ?                ; free memory in paragraphs
numFormat       db '@$'

LogoString      db '²',25,'±',25,'°',25,' ',31,'B',27,'l',27,'a',27,'c',27
                db 'k',27,' ',27,'I',27,'c',27,'e',27,' ',27,'T',29,'S',29
                db 'R',29,'-',29,'M',29,'C',29,'B',29,' ',29,'°',25,'±',25
                db '²',25,0
form_Avail      db '[FREEMEM=@K]$'
ExplString      db 'Ú',23,'Ä',23,'Ä',23,'Ä',23,'Ä',23,'Ä',23,'Ä',23,' ',23
                db 'B',31,'L',31,'O',31,'C',31,'K',31,' ',31,'Ä',23,'Ä',23
                db 'Ä',23,'Ä',23,'Ä',23,'Ä',23,'¿',23,' ',23,' ',23,'Ú',23
                db 'Ä',23,'Ä',23,'Ä',23,' ',23,'O',31,'W',31,'N',31,'E',31
                db 'R',31,' ',31,'Ä',23,'Ä',23,'Ä',23,'¿',23,0
HeaderString    db 'No  Id    Seg   Size    PSP     Name',0
InfoString      db 'Use ',24,25,' to scroll, ESC to exit',0

ssUndef         db '<undefn>',0
ssFree          db 69,'<free>',0
ssDrDosXmsUmb   db 65,'<DrDos XMS UMB>',0
ssDrDosExclUmb  db 65,'<DrDos ex. UMB>',0
ssBelongsToDos  db 65,'<owned by Dos>',0
ss386Max        db 68,'<386MAX>',0
ssIllegal       db 66,'<Illegal PSP>',0
ssBroken        db '(CHAIN CORRUPTED)',0
ssTooMany       db '(TOO MANY MCBs)',0
ssTable         dw ssFree,ssIllegal,ssIllegal,ssIllegal,ssIllegal,ssIllegal
                dw ssDrDosXmsUmb,ssDrDosExclUmb,ssBelongsToDos,ssIllegal
                dw ss386Max,ssIllegal,ssIllegal,ss386Max,ss386Max,ss386Max

legaltable      dd 000000000h,003FF23FAh,0C7FFFFFFh,06FFFFFFFh
                dd 0FFFFFFFFh,0FFFFFFFFh,0FFFFFFFFh,0FFFFFFFFh

scr_x           dw ?
scr_y           dw ?
swap_addr       dw ?
x_adjust        dw ? ; needed when added support to screen sizes other
                     ; than 80x25

;----------------------------------------------------------------------------
; þ NEW KEYBOARD INTERRUPT CODE |
;----------------------------------------------------------------------------

Keyboard:       pushf
                push ds es

                push cs            ; set [DS,ES] = CS
                push cs
                pop ds
                pop es

                call GetScreenSize ; get it now for later use
                cmp scr_x,43       ; if screen is less than 43 chars wide,
                jb toosmall        ; then this prog won't work!!!

                call MainController

toosmall:       pop es ds
                popf
                retf

;----------------------------------------------------------------------------
; þ PROCEDURES (principal: they save all registers, unless otherwise noted) |
;----------------------------------------------------------------------------

GetScreenSize   PROC NEAR
                push ax bx dx es
                mov ax,40h
                mov es,ax
                mov ax,word ptr es:4Ah
                mov scr_x,ax
                sub ax,80
                mov x_adjust,ax
                mov al,byte ptr es:84h
                xor ah,ah
                inc ax
                mov scr_y,ax
                mov bx,scr_x
                mul bx
                shl ax,1
                mov swap_addr,ax
                pop es dx bx ax
                ret
GetScreenSize   ENDP

Check_VKey      proc near ; output: if CARRY SET, then 'v/V' was pressed
                cmp al,'v'
                jz yesv
                cmp al,'V'
                jz yesV
                clc
                ret
yesv:           push ax bx cx dx si
                mov ah,colorVers
                mov bx,58
                mov cx,2
                lea si,str_vers
                xor dl,dl
                call putstring
                pop si dx cx bx ax
                stc
                ret
Check_VKey      endp

MainController  proc near
;Note:          þ Local globals: BL = first MCB on screen
;                                BH = last  ---- " " ----
;                                DL = mcbCount

                push ax bx cx dx si
                call DrawInitScreen
                call GetSegments
                jnc segmok
                mov ah,colorSpec
                mov bx,63
                mov cx,14
                lea si,ssTooMany
                xor dl,dl
                call PutString
segmok:         mov dl,mcbCount
                mov bl,1
                mov bh,9
                mov cx,5
                cmp dl,9
                jnb rightoway
                mov bh,dl
rightoway:      call PrintMCBs
                cmp mcbBroken,true
                jnz nobr
                push bx dx
                mov ah,colorSpec
                mov bx,43
                mov cx,14
                lea si,ssBroken
                xor dl,dl
                call PutString
                pop dx bx
nobr:           cmp dl,9
                ja yescrol
akey:           xor ax,ax
                int 16h
                call check_vkey
                jc akey
                cmp al,1Bh
                jnz akey
final:          call RestoreScreen
                pop si dx cx bx ax
                ret
yescrol:        xor ax,ax
                int 16h
                call check_vkey
                jc yescrol
                cmp ah,50h
                jz downarrow
                cmp ah,48h
                jz uparrow
                cmp al,1Bh
                jz final
                jnz yescrol
uparrow:        cmp bl,1
                jz yescrol
                dec bl
                dec bh
printem:        retrace
                call BlankDataArea
                mov cx,5
                call PrintMCBs
                jmp yescrol
downarrow:      cmp bh,dl
                jnb yescrol
                inc bl
                inc bh
                jmp printem
MainController  endp

BlankDataArea   proc near  ; dirties AX CX SI DI
                push bx
                mov ax,colorBack*256+' '
                mov bx,42+stradjust
                mov cx,5
                mov si,79+stradjust
                mov di,13
                call FillArea
                pop bx
                ret
BlankDataArea   endp

GetSegments     proc near
                push ax bx cx si di
                mov word ptr memFreeP,0
                cld
                mov ax,0ffffh
                mov cx,maxMCB
                lea di,mcbSegments
                push di
                rep stosw               ; clear old segments
                pop di
                xor cl,cl               ; zero counter
                mov ax,first_mcb
luuppi:         stosw
                inc cl
                cmp cl,maxMCB
                jna notexceed
                dec cl
                mov mcbCount,cl
                mov mcbBroken,false
                stc
                jmp poppi
notexceed:      push es
                mov es,ax
                mov bx,word ptr [es:3]
                cmp word ptr [es:1],0
                jnz dont_add
                add word ptr memFreeP,bx
dont_add:       add ax,bx
                inc ax
                mov es,ax
                mov bl,byte ptr [es:0]
                pop es
                cmp bl,4dh
                jz luuppi
                cmp bl,5ah
                jz last
                mov mcbCount,cl
                mov mcbBroken,true
                clc
poppi:          pop di si cx bx ax
                ret
last:           stosw
                push es
                mov es,ax
                cmp word ptr [es:1],0
                jnz da2
                mov bx,word ptr [es:3]
                add word ptr memFreeP,bx
da2:            pop es
                inc cl
                mov mcbCount,cl
                mov mcbBroken,false
                call PrintFree
                clc
                jmp poppi
GetSegments     endp

Intelligence    proc near
;Output:        CF clear ==> MCB name makes sense | CF set ==> name is trash

                push ax cx dx si di
                cld
                mov cx,8
                lea si,pMCBdata+8
iloop:          lodsb
                or al,al
                jz endii

                push cx
                mov ah,al
                mov cl,3
                shr al,cl
                mov dl,al
                xor dh,dh
                mov di,dx
                shl al,cl
                sub ah,al
                mov cl,ah
                mov al,1
                shl al,cl
                pop cx
                add di,offset legaltable
                mov ah,byte ptr [di]
                and ah,al
                jnz intel

                stc

pop_n_away:     pop di si dx cx ax
                ret
intel:          loop iloop
endii:          clc
                jnc pop_n_away
Intelligence    endp

PrintFree       proc near
                push ax bx cx dx si
                mov bx,memFreeP
                mov cl,6
                shr bx,cl
                xor dx,dx
                lea si,form_Avail
                mov cl,des
                call make_blis
                mov ah,colorAvail
                mov bx,43
                mov cx,2
                lea si,blis
                mov dl,'$'
                call PutString
                pop si dx cx bx ax
                ret
PrintFree       endp

PrintMCBs       proc near
;Params:        BL=number of first MCB (BL>0), BH=number of last MCB,
;               CX=starting line

                push bx cx

copydata:       push ax bx cx si di ds
                lea si,mcbSegments
                xor bh,bh
                dec bx
                shl bx,1
                mov ax,word ptr [bx+si]
                mov pCurSeg,ax
                mov ds,ax
                xor si,si
                lea di,pMCBdata
                mov cx,16
                cld
                rep movsb
                pop ds di si cx bx ax

ordnumber:      push ax bx dx si
                xor dx,dx
                xor bh,bh
                lea si,numFormat
                push cx
                mov cl,des
                call Make_Blis
                mov ah,colorData
                mov bx,42
                pop cx
                lea si,Blis
                mov dl,'$'
                call PutString
                pop si dx bx ax

idchar:         push ax bx dx di
                mov dh,byte ptr pMCBdata
                lea di,pMCBdata+5
                push cx
                mov cl,2
                call Int_to_Hex
                mov ah,colorData
                mov bx,45+stradjust
                pop cx
                mov al,byte ptr pMCBdata+5
                call FastPutChar
                mov al,byte ptr pMCBdata+6
                inc bx
                call FastPutChar
                mov ah,colorNdat
                mov al,'='
                inc bx
                call FastPutChar
                mov ah,colorData
                mov al,byte ptr pMCBdata
                inc bx
                call FastPutChar
                pop di dx bx ax

blocksegment:   push ax bx dx si di
                mov dx,pCurSeg
                lea di,temp_numbers
                push cx
                mov cl,4
                call Int_To_Hex
                mov byte ptr temp_numbers+4,0
                mov ah,colorData
                mov bx,51
                pop cx
                lea si,temp_numbers
                xor dl,dl
                call PutString
                mov ah,colorNdat
                mov al,'h'
                mov bx,55+stradjust
                call FastPutChar
                pop di si dx bx ax

blocksize:      push ax bx dx si
                push cx
                mov bx,word ptr pMCBdata+3
                mov dx,bx
                mov cl,12
                shr dx,cl
                mov cl,4
                shl bx,cl
                lea si,numFormat
                mov cl,des
                call Make_Blis
                mov bx,60
                shr cl,1
                xor ch,ch
                sub bx,cx
                pop cx
                mov ah,colorData
                lea si,Blis
                mov dl,'$'
                call PutString
                pop si dx bx ax

                push dx
                mov dx,word ptr pMCBdata+1
                cmp dx,9
                jb specialseg
                cmp dx,0fff9h
                ja specialseg
                jmp pspsegment

specialseg:     push ax bx si
                mov bx,dx
                and bx,0fh
                shl bx,1
                lea si,ssTable
                mov si,word ptr [bx+si]
                mov ah,colorSpec
                mov bl,byte ptr [si]
                inc si
                xor bh,bh
                xor dl,dl
                call PutString
                pop si bx ax dx
                jmp mainloop

pspsegment:     push ax bx si di
                lea di,temp_numbers
                push cx
                mov cl,4
                call Int_To_Hex
                mov byte ptr temp_numbers+4,0
                mov ah,colorData
                mov bx,65
                pop cx
                lea si,temp_numbers
                xor dl,dl
                call PutString
                mov ah,colorNdat
                mov al,'h'
                mov bx,69+stradjust
                call FastPutChar
                pop di si bx ax dx

ownername:      push ax bx dx si
                call Intelligence
                jnc goodboy
                mov ah,colorSpec
                lea si,ssUndef
                jmp tohere
goodboy:        mov ah,colorData
                lea si,pMCBdata+8
tohere:         mov bx,72
                xor dl,dl
                call PutString
                pop si dx bx ax

mainloop:       inc bl
                inc cx
                cmp bl,bh
                ja pout
                jmp copydata
pout:           pop cx bx
                ret

pMCBdata        db 16 dup(?)
pMCBterm        db 0
pCurSeg         dw ?
PrintMCBs       endp

SwapScreen      proc near  ; set SI and DI to proper values before calling
                push ax cx si di ds es
                mov ax,0b800h
                mov ds,ax
                mov es,ax
                cld
                mov cx,swap_addr
                rep movsb
                pop es ds di si cx ax
                ret
SwapScreen      endp

RestoreScreen   proc near
                push si di
                mov si,swap_addr
                xor di,di
                call SwapScreen
                pop di si
                ret
RestoreScreen   endp

DrawInitScreen  proc near
                push ax bx cx dx si di
                xor si,si
                mov di,swap_addr
                call SwapScreen
                retrace
                mov bx,40+(stradjust+1)
                mov cx,2
                mov si,81+(stradjust+1)
                mov di,17
                call ShadowArea
                mov ax,colorBord*256+charBorder
                mov bx,39+(stradjust+1)
                mov cx,1
                mov si,80+(stradjust+1)
                mov di,16
                call FillArea
                mov ax,1020h
                inc bx
                inc cx
                dec si
                dec di
                call FillArea
                mov ah,80h
                mov bx,48
                dec cx
                lea si,LogoString
                xor dl,dl
                call PutString
                mov bx,42
                inc cx
                inc cx
                lea si,ExplString
                call PutString
                inc cx
                lea si,HeaderString
                mov ah,colorHead
                call PutString
                mov bx,46
                mov cx,15
                mov ah,colorInfo
                lea si,InfoString
                call PutString
                pop di si dx cx bx ax
                ret
DrawInitScreen  endp

INT_TO_HEX      PROC NEAR       ; customized version from NUMBERS.ASM
;ßßßßßßßßßßßßßßßßßßßßßßßß
;Params:        DX:BX = 32-bit number, ES:DI -> buffer (MSB first),
;               CL    = number of nybbles to convert
;Note:          þ Remember the order: BYTE in DH, WORD in DX, DWORD in DX:BX
;Output:        Buffer filled

                push ax bx cx dx di
                cld
                xor ch,ch
ith1:           push cx
                mov al,dh
                mov cl,4
                shr al,cl
                add al,'0'
                cmp al,'9'
                jna ith2
                add al,7
ith2:           stosb
                shl dx,cl
                mov al,bh
                shr al,cl
                or dl,al
                shl bx,cl
                pop cx
                loop ith1
                pop di dx cx bx ax
                ret
INT_TO_HEX      ENDP

INT_TO_DEC      PROC NEAR
;ßßßßßßßßßßßßßßßßßßßßßßßß
;Params:        DX:BX = 32-bit number, ES:DI -> 10-byte buffer (MSB first)
;Output:        Buffer filled

                push ax bx cx dx si di
                push di
                cld
                mov al,'0'
                mov cx,10
                rep stosb
                pop di
                xor si,si
itdload:        mov ax, word ptr [dec_table+si]
                mov cx, word ptr [dec_table+si+2]
                add si,4
itdcomp:        cmp cx,dx
                ja itdno
                jb itdskip
                cmp ax,bx
                ja itdno
itdskip:        sub bx,ax
                sbb dx,cx
                inc byte ptr [es:di]
                jnz itdcomp
itdno:          inc di
                cmp si,40
                jnz itdload
                pop di si dx cx bx ax
                ret
dec_table       dd 1000000000,100000000,10000000,1000000,100000,10000,1000
                dd 100,10,1
INT_TO_DEC      ENDP

MAKE_BLIS       PROC NEAR
;ßßßßßßßßßßßßßßßßßßßßßßßß
;Params:        DX:BX = 32-bit number, DS:SI -> BLIS format,
;               CL = output type (des or hex)
;Output:        variable "blis" build, CL = length of blis excl. terminator
;BLIS format:   [<text>] <'@'> [<text>] <'$'>  ex. 'number @ is the best$'
;Note:          þ BLIS format must not exceed 80 bytes in length

                cmp cl,hex
                jna mbok
                ret
mbok:           mov mbBlisLen,0
                push ax si di es
                push cs
                pop es
                cld
                lea di,temp_numbers
                push cx di
                mov cx,11
                mov al,' '
                rep stosb
                pop di cx
                cmp cl,des
                jz mbcalld
                push cx
                mov cl,8
                call int_to_hex
                pop cx
                jmp mbsk1
mbcalld:        call int_to_dec
mbsk1:          lea di,blis
mbl1:           lodsb
                cmp al,'@'
                jz mbout
                stosb
                inc mbBlisLen
                jmp mbl1
mbout:          push si
                lea si,temp_numbers
                mov flaggy,0
mbl2:           lodsb
                cmp al,' '
                jz mbout2
                cmp al,'0'
                jnz sure
                cmp flaggy,0
                jnz sure
                jmp mbl2
sure:           mov flaggy,1
                stosb
                inc mbBlisLen
                jmp mbl2
mbout2:         cmp flaggy,0
                jnz skipit
                mov al,'0'
                stosb
                inc mbBlisLen
skipit:         pop si
mbl3:           lodsb
                cmp al,'$'
                jz mbout3
                stosb
                inc mbBlisLen
                jmp mbl3
mbout3:         stosb
                pop es di si ax
                mov cl,mbBlisLen
                ret
blis            db 90 dup(?)
temp_numbers    db 11 dup(?)
mbBlisLen       db ?
flaggy          db ?
MAKE_BLIS       ENDP

FastPutChar     PROC NEAR
;INPUT          AH=attribute, AL=character, BX=x(1-80), CX=y(1-25)
                push bx cx dx es di ax
                add bx,cs:x_adjust
                dec cx
                mov ax,scr_x
                shl ax,1
                mul cx
                mov di,ax
                dec bx
                shl bx,1
                add di,bx
                mov ax,0B800h
                mov es,ax
                pop ax
                stosw
                pop di es dx cx bx
                ret
FastPutChar     ENDP

FastGetChar     PROC NEAR
;INPUT          BX=x(1-80), CX=y(1-25)
;RETURN         AH=attribute, AL=character
                push bx cx dx ds si
                add bx,cs:x_adjust
                dec cx
                mov ax,scr_x
                shl ax,1
                mul cx
                mov si,ax
                dec bx
                shl bx,1
                add si,bx
                mov ax,0B800h
                mov ds,ax
                lodsw
                pop si ds dx cx bx
                ret
FastGetChar     ENDP

PUTSTRING       PROC NEAR
;ßßßßßßßßßßßßßßßßßßßßßßßß
;INPUT          AH=attribute, BX=x(1-80), CX=y(1-25), DS:SI -> STRING
;               DL=terminator char
;RETURN         -
;NOTES          þ Wraps text if necessary
;               þ If AH=80h then attr. is included in string (every 2nd byte)

                push ax si bx cx
                cld
                add bx,stradjust
                mov psFlag,ah
psl1:           cmp psFlag,80h
                jnz psj1
                lodsw
                jmp psj2
psj1:           lodsb
psj2:           cmp al,dl
                jz endo
                call fastputchar
                inc bx
                jmp psl1
endo:           pop cx bx si ax
                ret
psFlag          db ?
PUTSTRING       ENDP

FILLAREA        PROC NEAR
;ßßßßßßßßßßßßßßßßßßßßßßßß
;INPUT          AH=attribute, AL=character, BX=x1(1-80), CX=y1(1-25)
;               SI=x2(1-80), DI=y2(1-25)
;RETURN         -

                push cx
luup2:          push bx
luup1:          call FastPutChar
                inc bx
                cmp bx,si
                jbe luup1
                pop bx
                inc cx
                cmp cx,di
                jbe luup2
                pop cx
                ret
FILLAREA        ENDP

SHADOWAREA      PROC NEAR
;------------------------------+
; - Lays a shadow over an area |
; Input: BX     = x1 (1-80)    |
;        CX     = y1 (1-25)    |
;        SI     = x2 (1-80)    |
;        DI     = y2 (1-25)    |
; After: -                     |
;------------------------------+

                push cx
sh_l2:          push bx
sh_l1:          call FastGetChar
                and ah,87h
                cmp ah,7
                jnz skipe
                inc ah
skipe:          call FastPutChar
                inc bx
                cmp bx,si
                jbe sh_l1
                pop bx
                inc cx
                cmp cx,di
                jbe sh_l2
                pop cx
                ret
SHADOWAREA      ENDP

ENDING:
;----------------------------------------------------------------------------
; þ NON-RESIDENT PORTION PROCEDURES |
;----------------------------------------------------------------------------

GetFirstMCB     proc near
                push ax bx es
                mov ah,52h
                int 21h
                sub bx,2
                mov ax,word ptr [es:bx]
                mov first_mcb,ax
                pop es bx ax
                ret
GetFirstMCB     endp

;----------------------------------------------------------------------------
; þ INSTALLER |
;----------------------------------------------------------------------------

its_form        db 'MC'
                dw Keyboard,?
                db 'TSR-MCB         '

lf              equ 10,13
e               equ lf,'$'
already         db lf,'TSR-MCB already installed.',e
installed       db lf,'Black Ice TSR-MCB v1.2 is now resident.',e
noits           db lf,'This program requires ITS system.',e
listfull        db lf,'ITS system full.',e

IFDEF DEBUG

Real_Start:     mov ah,4Ah
                mov bx,(65536/16)
                int 21h
                call GetFirstMCB
                call GetScreenSize
                call MainController
                int 20h

ELSE

Real_Start:     xor ax,ax
                mov dx,'BI'
                int 3Eh
                cmp dx,'OK'
                jz itsins
                print noits
                int 20h
itsins:         mov word ptr its_form+4,cs
                mov ax,1
                mov dx,'BI'
                lea si,its_form
                int 3Eh
                cmp dx,'OK'
                jz oktogo
                or dx,dx
                jz werealre
                print listfull
                int 20h
werealre:       print already
                int 20h
oktogo:         call GetFirstMCB
                print installed
                mov ax,3100h
                lea dx,ending
                add dx,15
                mov cl,4
                shr dx,cl
                int 21h

ENDIF

END Start
