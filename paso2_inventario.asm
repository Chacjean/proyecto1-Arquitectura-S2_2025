; ------------------------------------------------------------
; PASO 2: Leer y procesar inventario.txt (incluye Paso 1 de config)
; Ensamblar y ejecutar:
;   nasm -f elf64 -g -F dwarf -o paso2_inventario.o paso2_inventario.asm
;   ld -m elf_x86_64 -o paso2_inventario paso2_inventario.o
;   ./paso2_inventario
; ------------------------------------------------------------

; == Syscalls Linux x86_64 ==
%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

%define O_RDONLY   0

; == Límites de inventario ==
%define NAME_MAX   32
%define MAX_ITEMS  64

section .data
    ; --- archivos ---
    fname_config        db "config.ini", 0
    fname_inv           db "inventario.txt", 0

    ; --- claves de config ---
    key_bar_char:       db "caracter_barra:"
    key_bar_char_len    equ $ - key_bar_char

    key_color_bar:      db "color_barra:"
    key_color_bar_len   equ $ - key_color_bar

    key_color_bg:       db "color_fondo:"
    key_color_bg_len    equ $ - key_color_bg

    ; --- mensajes ---
    msg_err_open_cfg    db "Error: no se pudo abrir config.ini", 10
    msg_err_open_cfg_len equ $ - msg_err_open_cfg

    msg_err_read_cfg    db "Error: no se pudo leer config.ini", 10
    msg_err_read_cfg_len equ $ - msg_err_read_cfg

    msg_err_open_inv    db "Error: no se pudo abrir inventario.txt", 10
    msg_err_open_inv_len equ $ - msg_err_open_inv

    msg_err_read_inv    db "Error: no se pudo leer inventario.txt", 10
    msg_err_read_inv_len equ $ - msg_err_read_inv

    ; Verificación de config (igual al Paso 1)
    msg_parsed_1        db "caracter_barra: '"
    msg_parsed_1_len    equ $ - msg_parsed_1
    msg_parsed_2        db "'", 10, "color_barra: "
    msg_parsed_2_len    equ $ - msg_parsed_2
    msg_parsed_3        db 10, "color_fondo: "
    msg_parsed_3_len    equ $ - msg_parsed_3
    msg_newline         db 10
    msg_newline_len     equ $ - msg_newline

    ; Verificación de inventario
    msg_inv_header      db 10, "-- Inventario (sin ordenar) --", 10
    msg_inv_header_len  equ $ - msg_inv_header

    msg_sep_colon_space db ": ", 0
    msg_sep_colon_space_len equ $ - msg_sep_colon_space - 1

section .bss
    ; --- buffers de lectura ---
    config_buf      resb 2048
    config_len      resq 1

    inv_buf         resb 4096
    inv_len         resq 1

    ; --- config parseada ---
    bar_bytes       resb 8
    bar_len         resd 1
    color_barra     resd 1
    color_fondo     resd 1

    ; --- estructuras de inventario ---
    item_names      resb MAX_ITEMS * NAME_MAX
    item_name_len   resb MAX_ITEMS
    item_values     resd MAX_ITEMS
    item_count      resd 1

    ; buffer para imprimir números
    num_buf         resb 16
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
; u32 -> decimal ASCII en num_buf; devuelve RSI, RDX
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
    div rbx
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
; find_key (corregido: sin 3 registros en direcciones)
; IN: RSI=buf, RDX=len, RDI=key, RCX=lenkey
; OUT: RAX = ptr tras la clave o 0
; ------------------------------------------------------------
find_key:
    push r8
    push r9
    push r10
    push r11
    push rbx
    push rdx
    mov r8, rsi
    mov r9, rdx
    mov r10, rdi
    mov r11, rcx
    xor rax, rax
    xor rdi, rdi      ; i=0
    cmp r9, r11
    jb .not_found
.outer:
    mov rax, rdi
    add rax, r11
    cmp rax, r9
    ja  .not_found
    xor rcx, rcx      ; j=0
.inner:
    cmp rcx, r11
    je .match
    mov rax, rdi
    add rax, rcx
    mov bl, [r8 + rax]
    mov dl, [r10 + rcx]
    cmp bl, dl
    jne .next_i
    inc rcx
    jmp .inner
.match:
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
; skip_spaces: avanza espacios/tabs desde RAX
; OUT: RAX pos no-espacio
; ------------------------------------------------------------
skip_spaces:
.next:
    mov bl, [rax]
    cmp bl, ' '
    je .adv
    cmp bl, 9          ; '\t'
    je .adv
    ret
.adv:
    inc rax
    jmp .next

; ------------------------------------------------------------
; read_bar_token: copia hasta fin de línea a bar_bytes (máx 8)
; IN: RAX=ptr inicio token
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
    cmp al, 10         ; \n
    je .done
    cmp al, 13         ; \r
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
; parse_uint: RDI=ptr, EAX=valor, RDI termina en 1er no-dígito
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
; parse_inventory: lee inv_buf y llena estructuras
; IN: RSI=ptr buf, RDX=len
; OUT: item_count
; ------------------------------------------------------------
parse_inventory:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rax

    mov r8, rsi                ; base buf
    mov r9, rdx                ; len
    mov r10, r8
    add r10, r9                ; end = base + len

    xor ecx, ecx                 ; idx = 0
    lea r13, [item_names]      ; base nombres
    lea r14, [item_name_len]   ; base longitudes
    lea r15, [item_values]     ; base valores

    mov rdi, r8                ; cursor p

.main_loop:
    cmp rdi, r10
    jae .done_all

    ; saltar líneas vacías y espacios iniciales
.skip_ws:
    cmp rdi, r10
    jae .done_all
    mov al, [rdi]
    cmp al, 10           ; \n
    je .adv1
    cmp al, 13           ; \r
    je .adv1
    cmp al, ' '
    je .adv1
    cmp al, 9            ; \t
    je .adv1
    jmp .start_name
.adv1:
    inc rdi
    jmp .skip_ws

.start_name:
    ; dest = item_names + idx*NAME_MAX
    mov rax, rcx
    shl rax, 5                 ; *32
    mov r12, r13
    add r12, rax               ; r12 = dest nombre

    xor edx, edx               ; name_len_temp = 0
    xor esi, esi               ; last_nonspace_len = 0

.name_loop:
    cmp rdi, r10
    jae .line_end_bad          ; fin sin ':'
    mov al, [rdi]
    cmp al, ':'                ; separador
    je .after_colon
    cmp al, 10                 ; \n -> línea inválida
    je .line_end_bad
    cmp al, 13                 ; \r -> fin de línea
    je .line_end_bad

    ; copiar char si cabe
    cmp edx, NAME_MAX
    jae .inc_only
    mov [r12 + rdx], al
.inc_only:
    inc edx                    ; name_len_temp++
    ; actualizar último no-espacio
    cmp al, ' '
    je .next_ch
    cmp al, 9
    je .next_ch
    mov esi, edx               ; last_nonspace_len = name_len_temp
.next_ch:
    inc rdi
    jmp .name_loop

.after_colon:
    inc rdi                    ; saltar ':'
    ; trim: longitud final = ESI
    ; guardar en item_name_len[idx]
    mov rbx, rcx               ; offset en array de longitudes
    mov rax, r14
    add rax, rbx
    mov bl, sil
    mov [rax], bl

    ; parsear número: saltar espacios
    mov rax, rdi
    call skip_spaces           ; RAX -> 1er no-espacio
    mov rdi, rax
    call parse_uint            ; EAX=valor, RDI termina tras dígitos
    ; guardar valor en item_values[idx]
    mov rbx, rcx
    mov [r15 + rbx*4], eax

    ; avanzar a fin de línea
.skip_to_eol:
    cmp rdi, r10
    jae .count_and_next
    mov al, [rdi]
    cmp al, 10
    je .eol_hit
    cmp al, 13
    je .eol_hit
    inc rdi
    jmp .skip_to_eol
.eol_hit:
    inc rdi
.count_and_next:
    inc ecx
    cmp ecx, MAX_ITEMS
    jb .main_loop
    jmp .done_all

.line_end_bad:
    ; línea sin ':' o vacía -> saltar hasta \n
.skip_bad:
    cmp rdi, r10
    jae .main_loop
    mov al, [rdi]
    inc rdi
    cmp al, 10
    jne .skip_bad
    jmp .main_loop

.done_all:
    mov [item_count], ecx

    pop rax
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ------------------------------------------------------------
; print_inventory: imprime cada "nombre: valor"
;  - Usa r12d para conservar item_count (syscall clobbera rcx/r11)
; ------------------------------------------------------------
print_inventory:
    push r12
    push r13
    push r14
    push r15
    push rbx
    push rdx
    push rsi
    push rdi
    push rax

    mov eax, [item_count]
    mov r12d, eax             ; item_count fijo durante todo el loop

    test r12d, r12d
    jz .done

    lea r13, [item_names]
    lea r14, [item_name_len]
    lea r15, [item_values]

    xor ebx, ebx               ; i = 0

.loop_i:
    ; ptr nombre = base + i*NAME_MAX (32)
    mov rax, rbx
    shl rax, 5                 ; *32
    mov rdi, r13
    add rdi, rax               ; rdi = ptr nombre

    ; len nombre = item_name_len[i]
    movzx edx, byte [r14 + rbx]

    ; print nombre
    mov rsi, rdi
    call write_stdout          ; syscall clobbera rcx/r11, pero no r12

    ; print ": "
    mov rsi, msg_sep_colon_space
    mov rdx, msg_sep_colon_space_len
    call write_stdout

    ; valor
    mov eax, [r15 + rbx*4]
    call u32_to_dec
    call write_stdout

    ; newline
    mov rsi, msg_newline
    mov rdx, msg_newline_len
    call write_stdout

    inc rbx
    cmp rbx, r12               ; ¡comparar con r12, no con rcx!
    jb .loop_i

.done:
    pop rax
    pop rdi
    pop rsi
    pop rdx
    pop rbx
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ------------------------------------------------------------
; _start
; ------------------------------------------------------------
_start:
    ; ====== Paso 1: leer config.ini ======
    mov rax, SYS_OPEN
    mov rdi, fname_config
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .err_open_cfg
    mov r12, rax

    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [config_buf]
    mov rdx, 2048
    syscall
    cmp rax, 0
    jle .err_read_cfg
    mov [config_len], rax

    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    ; caracter_barra
    lea rsi, [config_buf]
    mov rdx, [config_len]
    lea rdi, [key_bar_char]
    mov rcx, key_bar_char_len
    call find_key
    test rax, rax
    jz .cfg_color_bar
    call skip_spaces
    call read_bar_token
.cfg_color_bar:
    lea rsi, [config_buf]
    mov rdx, [config_len]
    lea rdi, [key_color_bar]
    mov rcx, key_color_bar_len
    call find_key
    test rax, rax
    jz .cfg_color_bg
    call skip_spaces
    mov rdi, rax
    call parse_uint
    mov [color_barra], eax
.cfg_color_bg:
    lea rsi, [config_buf]
    mov rdx, [config_len]
    lea rdi, [key_color_bg]
    mov rcx, key_color_bg_len
    call find_key
    test rax, rax
    jz .show_cfg
    call skip_spaces
    mov rdi, rax
    call parse_uint
    mov [color_fondo], eax

.show_cfg:
    ; Muestra breve confirmación de config
    mov rsi, msg_parsed_1
    mov rdx, msg_parsed_1_len
    call write_stdout
    lea rsi, [bar_bytes]
    mov edx, [bar_len]
    test edx, edx
    jz .skip_char
    call write_stdout
.skip_char:
    mov rsi, msg_parsed_2
    mov rdx, msg_parsed_2_len
    call write_stdout
    mov eax, [color_barra]
    call u32_to_dec
    call write_stdout
    mov rsi, msg_parsed_3
    mov rdx, msg_parsed_3_len
    call write_stdout
    mov eax, [color_fondo]
    call u32_to_dec
    call write_stdout
    mov rsi, msg_newline
    mov rdx, msg_newline_len
    call write_stdout

    ; ====== Paso 2: leer inventario.txt ======
    mov rax, SYS_OPEN
    mov rdi, fname_inv
    mov rsi, O_RDONLY
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .err_open_inv
    mov r12, rax

    mov rax, SYS_READ
    mov rdi, r12
    lea rsi, [inv_buf]
    mov rdx, 4096
    syscall
    cmp rax, 0
    jle .err_read_inv
    mov [inv_len], rax

    mov rax, SYS_CLOSE
    mov rdi, r12
    syscall

    ; parsear inventario
    lea rsi, [inv_buf]
    mov rdx, [inv_len]
    call parse_inventory

    ; imprimir verificación (sin ordenar)
    mov rsi, msg_inv_header
    mov rdx, msg_inv_header_len
    call write_stdout
    call print_inventory

    ; salir OK
    mov rax, SYS_EXIT
    xor rdi, rdi
    syscall

.err_open_cfg:
    mov rsi, msg_err_open_cfg
    mov rdx, msg_err_open_cfg_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 1
    syscall

.err_read_cfg:
    mov rsi, msg_err_read_cfg
    mov rdx, msg_err_read_cfg_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 2
    syscall

.err_open_inv:
    mov rsi, msg_err_open_inv
    mov rdx, msg_err_open_inv_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 3
    syscall

.err_read_inv:
    mov rsi, msg_err_read_inv
    mov rdx, msg_err_read_inv_len
    call write_stdout
    mov rax, SYS_EXIT
    mov rdi, 4
    syscall
