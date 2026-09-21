export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git rust fzf zsh-autosuggestions zsh-syntax-highlighting)
DISABLE_AUTO_UPDATE=true
DISABLE_UPDATE_PROMPT=true

HISTFILE="$HOME/.history/zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt inc_append_history hist_ignore_dups

source "$ZSH/oh-my-zsh.sh"

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export EDITOR=nvim VISUAL=nvim
alias vi=nvim
alias vim=nvim
alias yolo='claude --dangerously-skip-permissions'

# Visible reminder that this shell is inside the box
PROMPT="%F{yellow}[box]%f $PROMPT"
