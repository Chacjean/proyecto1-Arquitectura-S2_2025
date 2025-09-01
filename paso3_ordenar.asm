; ------------------------------------------------------------
; PASO 3: Ordenar alfabéticamente por nombre (incluye Paso 1 y 2)
; Ensamblar y ejecutar:
;   nasm -f elf64 -g -F dwarf -o paso3_ordenar.o paso3_ordenar.asm
;   ld -m elf_x86_64 -o paso3_ordenar paso3_ordenar.o
;   ./paso3_ordenar
; ------------------------------------------------------------

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

%define O_RDONLY   0

%define NAME_MAX   32
%define MAX_ITEMS  64

section .data
    fname_config        db "config.ini", 0
    fname_inv           db "inventario.txt", 0

    key_bar_char:       db "caracter_barra:"
    key_bar_char_len    equ $ - key_bar_char
    key_color_bar:      db "color_barra:"
    key_color_bar_len   equ $ - key_color_bar
    key_color_bg:       db "color_fondo:"
    key_color_bg_len    equ $ - key_color_bg

    msg_err_open_cfg    db "Error: no se pudo abrir config.ini", 10
    msg_err_open_cfg_len equ $ - msg_err_open_cfg
    msg_err_read_cfg    db "Error: no se pudo leer config.ini", 10
    msg_err_read_cfg_len equ $ - msg_err_read_cfg
    msg_err_open_inv    db "Error: no se pudo abrir inventario.txt", 10
    msg_err_open_inv_len equ $ - msg_err_open_inv
    msg_err_read_inv    db "Error: no se pudo leer inventario.txt", 10
    msg_err_read_inv_len equ $ - msg_err_read_inv

    msg_parsed_1        db "caracter_barra: '"
    msg_parsed_1_len    equ $ - msg_parsed_1
    msg_parsed_2        db "'", 10, "color_barra: "
    msg_parsed_2_len    equ $ - msg_parsed_2
    msg_parsed_3        db 10, "color_fondo: "
    msg_parsed_3_len    equ $ - msg_parsed_3
    msg_newline         db 10
    msg_newline_len     equ $ - msg_newline

    msg_inv_header      db 10, "-- Inventario (sin ordenar) --", 10
    msg_inv_header_len  equ $ - msg_inv_header
    msg_sorted_header   db 10, "-- Inventario (ordenado A-Z) --", 10
    msg_sorted_header_len equ $ - msg_sorted_header

    msg_sep_colon_space db ": ", 0
    msg_sep_colon_space_len equ $ - msg_sep_colon_space - 1

section .bss
    config_buf      resb 2048
    config_len      resq 1

    inv_buf         resb 4096
    inv_len         resq 1

    bar_bytes       resb 8
    bar_len         resd 1
    color_barra     resd 1
    color_fondo     resd 1

    item_names      resb MAX_ITEMS * NAME_MAX
    item_name_len   resb MAX_ITEMS
    item_values     resd MAX_ITEMS
    item_count      resd 1

    num_buf         resb 16
    num_len         resd 1

    temp_name       resb NAME_MAX   ; para swap de nombres (32 bytes)

section .text
    global _start

; ------------------ utilidades de IO ------------------------
write_stdout:
    mov rax, SYS_WRITE
    mov rdi, 1
    syscall
    ret

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

; ------------------ parseo de config ------------------------
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
    xor rdi, rdi
    cmp r9, r11
    jb .not_found
.outer:
    mov rax, rdi
    add rax, r11
    cmp rax, r9
    ja  .not_found
    xor rcx, rcx
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

skip_spaces:
.next:
    mov bl, [rax]
    cmp bl, ' '
    je .adv
    cmp bl, 9
    je .adv
    ret
.adv:
    inc rax
    jmp .next

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
    cmp al, 10
    je .done
    cmp al, 13
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

; ------------------ parseo de inventario --------------------
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

    mov r8, rsi
    mov r9, rdx
    mov r10, r8
    add r10, r9

    xor ecx, ecx               ; idx = 0  (¡arreglo del Paso 2!)
    lea r13, [item_names]
    lea r14, [item_name_len]
    lea r15, [item_values]

    mov rdi, r8

.main_loop:
    cmp rdi, r10
    jae .done_all

.skip_ws:
    cmp rdi, r10
    jae .done_all
    mov al, [rdi]
    cmp al, 10
    je .adv1
    cmp al, 13
    je .adv1
    cmp al, ' '
    je .adv1
    cmp al, 9
    je .adv1
    jmp .start_name
.adv1:
    inc rdi
    jmp .skip_ws

.start_name:
    mov rax, rcx
    shl rax, 5                 ; *32
    mov r12, r13
    add r12, rax               ; r12 = dest nombre

    xor edx, edx               ; name_len_temp
    xor esi, esi               ; last_nonspace_len

.name_loop:
    cmp rdi, r10
    jae .line_end_bad
    mov al, [rdi]
    cmp al, ':'
    je .after_colon
    cmp al, 10
    je .line_end_bad
    cmp al, 13
    je .line_end_bad

    cmp edx, NAME_MAX
    jae .inc_only
    mov [r12 + rdx], al
.inc_only:
    inc edx
    cmp al, ' '
    je .next_ch
    cmp al, 9
    je .next_ch
    mov esi, edx
.next_ch:
    inc rdi
    jmp .name_loop

.after_colon:
    inc rdi
    mov rbx, rcx
    mov rax, r14
    add rax, rbx
    mov bl, sil
    mov [rax], bl

    mov rax, rdi
    call skip_spaces
    mov rdi, rax
    call parse_uint
    mov rbx, rcx
    mov [r15 + rbx*4], eax

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

; ------------------ impresión de inventario -----------------
; Usa r12d para conservar item_count (syscall clobbera rcx/r11)
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
    mov r12d, eax

    test r12d, r12d
    jz .done

    lea r13, [item_names]
    lea r14, [item_name_len]
    lea r15, [item_values]

    xor ebx, ebx

.loop_i:
    mov rax, rbx
    shl rax, 5                 ; *32
    mov rdi, r13
    add rdi, rax               ; ptr nombre

    movzx edx, byte [r14 + rbx]

    mov rsi, rdi
    call write_stdout

    mov rsi, msg_sep_colon_space
    mov rdx, msg_sep_colon_space_len
    call write_stdout

    mov eax, [r15 + rbx*4]
    call u32_to_dec
    call write_stdout

    mov rsi, msg_newline
    mov rdx, msg_newline_len
    call write_stdout

    inc rbx
    cmp rbx, r12
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

; ------------------ ORDENAMIENTO ----------------------------
; compare_names(EBX=i, EDX=j) -> EAX: -1 si i<j, 0 si =, 1 si i>j
compare_names:
    push rsi
    push rdi
    push rcx
    push r8
    push r9

    ; Base arrays
    lea r8, [item_names]
    lea r9, [item_name_len]

    ; ptr_i = item_names + i*32
    mov rax, rbx
    shl rax, 5
    lea rsi, [r8 + rax]
    ; ptr_j = item_names + j*32
    mov rax, rdx
    shl rax, 5
    lea rdi, [r8 + rax]

    ; len_i, len_j
    movzx ecx, byte [r9 + rbx]
    movzx eax, byte [r9 + rdx]     ; eax = len_j
    mov r8d, ecx                   ; r8d = len_i
    mov r9d, eax                   ; r9d = len_j

    ; minlen en ecx
    cmp ecx, eax
    cmova ecx, eax                 ; ecx = min(len_i, len_j)

    ; loop k=0..minlen-1
    xor eax, eax                   ; eax como acumulador temporal
    xor r10d, r10d                 ; k=0
.cmp_loop:
    cmp r10d, ecx
    jae .after_prefix
    mov al, [rsi + r10]
    mov dl, [rdi + r10]
    cmp al, dl
    jne .diff
    inc r10d
    jmp .cmp_loop

.diff:
    ; a != b
    jb .less
    ja .greater

.after_prefix:
    ; prefijos iguales: decide por longitud
    mov eax, r8d                   ; len_i
    cmp eax, r9d                   ; len_j
    jb .less
    ja .greater
    xor eax, eax                   ; igual -> 0
    jmp .done

.less:
    mov eax, -1
    jmp .done
.greater:
    mov eax, 1

.done:
    pop r9
    pop r8
    pop rcx
    pop rdi
    pop rsi
    ret

; swap_items(EBX=i, EDX=j): intercambia nombre(32), len(1), valor(4)
swap_items:
    push rsi
    push rdi
    push rcx
    push rax

    ; ptr_i
    mov rax, rbx
    shl rax, 5
    lea rsi, [item_names + rax]
    ; ptr_j
    mov rax, rdx
    shl rax, 5
    lea rdi, [item_names + rax]

    ; temp = name[i]
    mov ecx, NAME_MAX
    lea rax, [temp_name]
    ; copiar i -> temp
    push rdi
    mov rdi, rax
    rep movsb

    ; copiar j -> i
    pop rdi
    mov rax, rdx
    shl rax, 5
    lea rsi, [item_names + rax]
    mov rax, rbx
    shl rax, 5
    lea rdi, [item_names + rax]
    mov ecx, NAME_MAX
    rep movsb

    ; copiar temp -> j
    lea rsi, [temp_name]
    mov rax, rdx
    shl rax, 5
    lea rdi, [item_names + rax]
    mov ecx, NAME_MAX
    rep movsb

    ; swap len
    mov al, [item_name_len + rbx]
    xchg al, [item_name_len + rdx]
    mov [item_name_len + rbx], al

    ; swap value (dword)
    mov eax, [item_values + rbx*4]
    xchg eax, [item_values + rdx*4]
    mov [item_values + rbx*4], eax

    pop rax
    pop rcx
    pop rdi
    pop rsi
    ret

; bubble_sort: ordena in-place por nombre (A-Z)
bubble_sort:
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
    mov r12d, eax          ; n
    cmp r12d, 1
    jbe .done

    xor r13d, r13d         ; pass = 0
.outer_pass:
    ; limit = n-1-pass
    mov r14d, r12d
    dec r14d
    sub r14d, r13d
    jle .done              ; si limit <= 0, listo

    xor r15d, r15d         ; swapped = 0
    xor ebx, ebx           ; i = 0
.inner_loop:
    mov edx, ebx
    inc edx                ; j = i+1

    ; compare(i, j)
    push rbx
    push rdx
    call compare_names
    pop rdx
    pop rbx
    cmp eax, 0
    jle .no_swap
    ; swap(i, j)
    push rbx
    push rdx
    call swap_items
    pop rdx
    pop rbx
    mov r15d, 1

.no_swap:
    inc ebx
    cmp ebx, r14d
    jb .inner_loop

    ; si no hubo swaps, ya está ordenado
    test r15d, r15d
    jz .done

    inc r13d
    jmp .outer_pass

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

; ------------------ programa principal ----------------------
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

    lea rsi, [inv_buf]
    mov rdx, [inv_len]
    call parse_inventory

    ; imprimir verificación (sin ordenar)
    mov rsi, msg_inv_header
    mov rdx, msg_inv_header_len
    call write_stdout
    call print_inventory

    ; ====== Paso 3: ordenar y volver a imprimir ======
    call bubble_sort
    mov rsi, msg_sorted_header
    mov rdx, msg_sorted_header_len
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
