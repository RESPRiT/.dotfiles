" Mouse support
set mouse=a

" Relative line numbers with current line showing absolute number
set number
set relativenumber

" Search
set hlsearch
set incsearch
set ignorecase
set smartcase

" Indentation
set tabstop=2
set shiftwidth=2
set expandtab
set autoindent
set smartindent

" Color scheme
set background=dark
let g:solarized_termtrans=1
silent! colorscheme solarized

" Display
set cursorline
highlight CursorLine cterm=NONE ctermbg=0 guibg=#073642
syntax on
set showmatch
set colorcolumn=120

" Persistent undo
set undofile
