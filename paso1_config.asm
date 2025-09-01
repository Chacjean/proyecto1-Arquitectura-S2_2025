; ------------------------------------------------------------
; PASO 1: Leer y procesar config.ini
; Ensamblar y ejecutar:
;   nasm -f elf64 -g -F dwarf -o paso1_config.o paso1_config.asm
;   ld -m elf_x86_64 -o paso1_config paso1_config.o
;   ./paso1_config
; ------------------------------------------------------------

; == Syscalls Linux x86_64 ==
%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

%define O_RDONLY   0

section .data
    fname_config        db "config.ini", 0

    ; Claves a buscar (sin terminador nulo; usamos 'equ' para longitudes)
    key_bar_char:       db "caracter_barra:"
    key_bar_char_len    equ $ - key_bar_char

    key_color_bar:      db "color_barra:"
    key_color_bar_len   equ $ - key_color_bar

    key_color_bg:       db "color_fondo:"
    key_color_bg_len    equ $ - key_color_bg

    ; Mensajes de depuración / verificación
    msg_ok              db "CONFIG leida correctamente", 10
    msg_ok_len          equ $ - msg_ok

    msg_err_open        db "Error: no se pudo abrir config.ini", 10
    msg_err_open_len    equ $ - msg_err_open

    msg_err_read        db "Error: no se pudo leer config.ini", 10
    msg_err_read_len    equ $ - msg_err_read

    msg_parsed_1        db "caracter_barra: '"
    msg_parsed_1_len    equ $ - msg_parsed_1
    msg_parsed_2        db "'", 10, "color_barra: "
    msg_parsed_2_len    equ $ - msg_parsed_2
    msg_parsed_3        db 10, "color_fondo: "
    msg_parsed_3_len    equ $ - msg_parsed_3
    msg_newline         db 10
    msg_newline_len     equ $ - msg_newline

section .bss
    ; Buffer para leer el config (tamaño suficiente)
    config_buf      resb 2048
    config_len      resq 1

    ; Donde guardamos los valores parseados
    bar_bytes       resb 8       ; hasta 8 bytes por seguridad (soporta UTF-8 multibyte)
    bar_len         resd 1

    color_barra     resd 1
    color_fondo     resd 1

    ; Buffer para imprimir enteros en decimal
    num_buf         resb 16      ; suficiente para 32-bit decimal
    num_len         resd 1

section .text
    global _start

; ------------------------------------------------------------
; write(1, rsi, rdx)
; ------------------------------------------------------------
write_stdout:
    mov rax, SYS_WRITE
    mov rdi, 1
    syscall
    ret

; ------------------------------------------------------------
; Convierte EAX (u32) a decimal ASCII.
;  - Escribe en num_buf, devuelve: RSI=ptr, RDX=len
; ------------------------------------------------------------
u32_to_dec:
    push rbx
    push rcx
    push rdx

    mov rcx, 0
    mov rbx, 10

    lea rdi, [num_buf + 15]
    mov byte [rdi], 0
    dec rdi

    cmp eax, 0
    jne .convert
    mov byte [rdi], '0'
    mov rcx, 1
    jmp .done

.convert:
    xor rdx, rdx
.repeat:
    xor rdx, rdx
    div rbx                 ; RAX=quot, RDX=rem
    add dl, '0'
    mov [rdi], dl
    dec rdi
    inc rcx
    test eax, eax
    jnz .repeat

.done:
    inc rdi
    mov rsi, rdi
    mov edx, ecx
    mov [num_len], edx

    pop rdx
    pop rcx
    pop rbx
    ret

; ------------------------------------------------------------
; Busca una subcadena (clave) en un buffer:
;  IN:  RSI=ptr buf, RDX=len buf
;       RDI=ptr key, RCX=len key
; OUT: RAX=ptr justo DESPUES de la clave si se encontró; 0 si no.
; (Corregido: sin direcciones con 3 registros)
; ------------------------------------------------------------
find_key:
    push r8
    push r9
    push r10
    push r11
    push rbx
    push rdx

    mov r8, rsi           ; base buf
    mov r9, rdx           ; len buf
    mov r10, rdi          ; base key
    mov r11, rcx          ; len key

    xor rax, rax
    xor rdi, rdi          ; i = 0

    cmp r9, r11
    jb .not_found

.outer:
    ; si (i + key_len) > buf_len -> no hay más coincidencias posibles
    mov rax, rdi
    add rax, r11
    cmp rax, r9
    ja  .not_found

    xor rcx, rcx          ; j = 0
.inner:
    cmp rcx, r11
    je .match

    ; bl = buf[i + j]
    mov rax, rdi
    add rax, rcx
    mov bl, [r8 + rax]

    ; dl = key[j]
    mov dl, [r10 + rcx]

    cmp bl, dl
    jne .next_i

    inc rcx
    jmp .inner

.match:
    ; rax = buf + i + key_len
    mov rax, rdi
    add rax, r11
    add rax, r8
    jmp .done

.next_i:
    inc rdi
    jmp .outer

.not_found:
    xor rax, rax

.done:
    pop rdx
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    ret

; ------------------------------------------------------------
; Salta espacios y tabs desde RAX hacia adelante.
; OUT: RAX = primer no-espacio
; ------------------------------------------------------------
skip_spaces:
.next:
    mov bl, [rax]
    cmp bl, ' '
    je .adv
    cmp bl, 9              ; '\t'
    je .adv
    ret
.adv:
    inc rax
    jmp .next

; ------------------------------------------------------------
; Lee token hasta fin de línea (\n o \r).
; Copia a bar_bytes y guarda longitud en bar_len (máx 8 bytes).
; IN:  RAX = ptr inicio del token
; ------------------------------------------------------------
read_bar_token:
    push rcx
    push rdx
    push rsi
    push rdi

    mov rsi, rax
    lea rdi, [bar_bytes]
    xor ecx, ecx

.copy_loop:
    mov al, [rsi]
    cmp al, 10             ; '\n'
    je .done
    cmp al, 13             ; '\r'
    je .done
    cmp ecx, 8
    jae .done
    mov [rdi + rcx], al
    inc rcx
    inc rsi
    jmp .copy_loop

.done:
    mov [bar_len], ecx

    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ------------------------------------------------------------
; Parsea entero decimal en EAX:
; IN:  RDI = ptr (ya sin espacios), termina en no-dígito
; OUT: EAX = valor
; ------------------------------------------------------------
parse_uint:
    xor eax, eax
.parse_loop:
    mov bl, [rdi]
    cmp bl, '0'
    jb .end
    cmp bl, '9'
    ja .end
    imul eax, eax, 10
    movzx ebx, bl
    sub ebx, '0'
    add eax, ebx
    inc rdi
    jmp .parse_loop
.end:
    ret

; ------------------------------------------------------------
; _start: abrir, leer, parsear y mostrar confirmación
; ------------------------------------------------------------
_start:
    ; open("config.ini", O_RDONLY)
    mov rax, SYS_OPEN
    mov rdi, fname_config
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .err_open
    mov r12, rax              ; fd

    ; read(fd, config_buf, sizeof)
    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [config_buf]
    mov rdx, 2048
    syscall
    cmp rax, 0
    jle .err_read
    mov [config_len], rax     ; guardar longitud

    ; close(fd)
    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    ; ====== caracter_barra ======
    lea rsi, [config_buf]
    mov rdx, [config_len]
    lea rdi, [key_bar_char]
    mov rcx, key_bar_char_len
    call find_key             ; RAX = ptr tras la clave
    test rax, rax
    jz .parsed_continue
    call skip_spaces          ; RAX actualizado
    call read_bar_token
.parsed_continue:

    ; ====== color_barra ======
    lea rsi, [config_buf]
    mov rdx, [config_len]
    lea rdi, [key_color_bar]
    mov rcx, key_color_bar_len
    call find_key
    test rax, rax
    jz .parsed_color_bg
    call skip_spaces
    mov rdi, rax
    call parse_uint
    mov [color_barra], eax
.parsed_color_bg:

    ; ====== color_fondo ======
    lea rsi, [config_buf]
    mov rdx, [config_len]
    lea rdi, [key_color_bg]
    mov rcx, key_color_bg_len
    call find_key
    test rax, rax
    jz .show_ok
    call skip_spaces
    mov rdi, rax
    call parse_uint
    mov [color_fondo], eax

.show_ok:
    ; ---- Verificación de salida ----
    ; "caracter_barra: '"
    mov rsi, msg_parsed_1
    mov rdx, msg_parsed_1_len
    call write_stdout

    ; el carácter (bar_bytes[0..bar_len))
    lea rsi, [bar_bytes]
    mov edx, [bar_len]
    test edx, edx
    jz .skip_char_print
    call write_stdout
.skip_char_print:

    ; "'\ncolor_barra: "
    mov rsi, msg_parsed_2
    mov rdx, msg_parsed_2_len
    call write_stdout

    ; número color_barra
    mov eax, [color_barra]
    call u32_to_dec
    call write_stdout

    ; "\ncolor_fondo: "
    mov rsi, msg_parsed_3
    mov rdx, msg_parsed_3_len
    call write_stdout

    ; número color_fondo
    mov eax, [color_fondo]
    call u32_to_dec
    call write_stdout

    ; newline final
    mov rsi, msg_newline
    mov rdx, msg_newline_len
    call write_stdout

    ; Fin OK
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

.err_open:
    mov rsi, msg_err_open
    mov rdx, msg_err_open_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

.err_read:
    mov rsi, msg_err_read
    mov rdx, msg_err_read_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 2
    syscall
