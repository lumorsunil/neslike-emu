nnoremap <F5> <Cmd>vnew \| term bash clear-cache.sh; ./dasm.exe test.dasm -f3 -otest.bin && zig build run -Dtarget=x86_64-windows<CR>
