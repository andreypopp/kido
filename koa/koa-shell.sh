#!/bin/sh
script=$1
shift
if [ "${KOA_COMPLETE_BASH-}" != 1 ]; then
  fallback=
  for bash in "$(command -v bash 2>/dev/null)" /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    [ -x "$bash" ] || continue
    [ -n "$fallback" ] || fallback=$bash
    if "$bash" --noprofile --norc -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]'; then
      KOA_COMPLETE_BASH=1 exec "$bash" --noprofile --norc -c "$script" koa-complete "$script" "$@"
    fi
  done
  [ -n "$fallback" ] || exit 0
  KOA_COMPLETE_BASH=1 exec "$fallback" --noprofile --norc -c "$script" koa-complete "$script" "$@"
fi
line=$1 point=$2
export LC_ALL=C
case $line in *'$('*|*'`'*|*'<<'*|*'<('*|*'>('*|*'('*|*')'*) exit 0;; esac
words=() starts=() ends=() redirs=()
word= quote= escaped=0 active=0 begin=0 selected=-1 redirectNext=0 commandEnd=${#line}
for ((i=0; i<=${#line}; i++)); do
  ch=${line:i:1}
  if ((escaped)); then [[ $ch != $'\n' ]] && word+=$ch; escaped=0; continue; fi
  if [[ $ch == \\ && $quote != "'" && ( $quote != '"' || ${line:i+1:1} == [\$\`\"\\] || ${line:i+1:1} == $'\n' ) ]]; then
    if (( !active )); then begin=$i; active=1; fi
    escaped=1; continue
  fi
  if [[ -n $quote ]]; then
    if [[ $ch == "$quote" ]]; then quote=; else word+=$ch; fi
    continue
  fi
  if [[ $ch == "'" || $ch == '"' ]]; then
    if (( !active )); then begin=$i; active=1; fi
    quote=$ch; continue
  fi
  if [[ -z $ch || $ch == ' ' || $ch == $'\t' || $ch == $'\n' || $ch == '|' || $ch == ';' || $ch == '&' || $ch == '<' || $ch == '>' ]]; then
    if ((active)); then
      words+=("$word"); starts+=("$begin"); ends+=("$i"); redirs+=("$redirectNext"); redirectNext=0
      if ((point>=begin && point<=i)); then selected=$((${#words[@]}-1)); fi
      word= active=0
    elif ((point==i && selected<0)); then
      words+=(""); starts+=("$i"); ends+=("$i"); redirs+=("$redirectNext"); selected=$((${#words[@]}-1))
    fi
    if [[ $ch == '|' || $ch == ';' || $ch == '&' || $ch == $'\n' ]]; then
      if ((i<point)); then words=(); starts=(); ends=(); redirs=(); selected=-1; redirectNext=0; elif ((i>=point)); then commandEnd=$i; break; fi
    fi
    if [[ $ch == '<' || $ch == '>' ]]; then
      redirectNext=1
      operator=$ch
      [[ ${line:i+1:1} == "$ch" ]] && { operator+=$ch; ((i++)); }
      words+=("$operator"); starts+=("$i"); ends+=("$((i+1))"); redirs+=(0)
    fi
  else
    if (( !active )); then begin=$i; active=1; fi
    word+=$ch
  fi
done
if ((active)); then
  words+=("$word"); starts+=("$begin"); ends+=("${#line}"); redirs+=("$redirectNext")
  if ((point>=begin)); then selected=$((${#words[@]}-1)); fi
fi
((selected>=0)) || exit 0
from=${starts[selected]} to=${ends[selected]}
prefix=${line:from:point-from}
cur= q= esc=0
for ((i=0;i<${#prefix};i++)); do
  ch=${prefix:i:1}
  if ((esc)); then [[ $ch != $'\n' ]] && cur+=$ch; esc=0
  elif [[ $ch == \\ && $q != "'" && ( $q != '"' || ${prefix:i+1:1} == [\$\`\"\\] || ${prefix:i+1:1} == $'\n' ) ]]; then esc=1
  elif [[ -n $q ]]; then if [[ $ch == "$q" ]]; then q=; else cur+=$ch; fi
  elif [[ $ch == "'" || $ch == '"' ]]; then q=$ch
  else cur+=$ch; fi
done
redir=${redirs[selected]}
COMP_WORDS=() COMP_CWORD=-1 start=-1
for ((i=0;i<${#words[@]};i++)); do
  value=${words[i]}
  if [[ $value == '<' || $value == '>' || $value == '>>' || ${redirs[i]} == 1 ]]; then continue; fi
  if [[ $value =~ ^[0-9]+$ && ( ${words[i+1]-} == '<' || ${words[i+1]-} == '>' || ${words[i+1]-} == '>>' ) && ${ends[i]} == ${starts[i+1]-} ]]; then continue; fi
  if ((${#COMP_WORDS[@]}==0)) && [[ $value =~ ^[a-zA-Z_][a-zA-Z_0-9]*= ]]; then continue; fi
  ((start<0)) && start=${starts[i]}
  if ((i==selected)); then COMP_CWORD=${#COMP_WORDS[@]}; value=$cur; fi
  COMP_WORDS+=("$value")
done
((COMP_CWORD>=0 || redir)) || exit 0
selected=$COMP_CWORD
COMP_TYPE=9 COMP_KEY=9
((start<0)) && start=0
COMP_LINE=${line:start:commandEnd-start}
p=${line:start:point-start}
COMP_POINT=${#p}
COMPREPLY=() filenames=0 nospace=0 default=0 bashdefault=0 dirnames=0 plusdirs=0
if ((BASH_VERSINFO[0]>=4)); then
  prefix=${BASH%/*}; prefix=${prefix%/*}
  for source in "${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/bash_completion" "$prefix/share/bash-completion/bash_completion" /usr/share/bash-completion/bash_completion; do
    if [[ -r $source ]]; then . "$source" >/dev/null 2>&1; break; fi
  done
fi
compopt() {
  local option add=1
  for option in "$@"; do
    case $option in -o) add=1;; +o) add=0;; filenames) filenames=$add;; nospace) nospace=$add;; default) default=$add;; bashdefault) bashdefault=$add;; dirnames) dirnames=$add;; plusdirs) plusdirs=$add;; esac
  done
}
command=${COMP_WORDS[0]}
registered=0
if ((selected>0 && !redir)); then
  if declare -F _comp_load >/dev/null; then _comp_load "$command" >/dev/null 2>&1
  elif declare -F _completion_loader >/dev/null; then _completion_loader "$command" >/dev/null 2>&1; fi
  for ((attempt=0;attempt<3;attempt++)); do
    spec=$(complete -p -- "$command" 2>/dev/null)
    filenames=0 nospace=0 default=0 bashdefault=0 dirnames=0 plusdirs=0
    [[ $spec == *' -o filenames '* ]] && filenames=1
    [[ $spec == *' -o nospace '* ]] && nospace=1
    [[ $spec == *' -o default '* ]] && default=1
    [[ $spec == *' -o bashdefault '* ]] && bashdefault=1
    [[ $spec == *' -o dirnames '* ]] && dirnames=1
    [[ $spec == *' -o plusdirs '* ]] && plusdirs=1
    if [[ $spec =~ ' -F '([^\ ]+) ]]; then
      function=${BASH_REMATCH[1]}
      function=${function#\'} function=${function%\'}
      if declare -F "$function" >/dev/null; then
        registered=1 COMPREPLY=()
        "$function" "$command" "$cur" "${COMP_WORDS[selected-1]}" >/dev/null 2>&1
        status=$?
        ((status==124)) && continue
      fi
    fi
    break
  done
  ((attempt==3 && status==124)) && COMPREPLY=()
fi
fileMatches=()
if (( !registered || (${#COMPREPLY[@]}==0 && (default || bashdefault || dirnames)) || plusdirs )); then
  if (( !registered && selected==0 && !redir)) && [[ $cur != */* ]]; then
    while IFS= read -r match; do COMPREPLY+=("$match"); done < <(compgen -c -- "$cur")
  else
    onlydirs=0
    if ((registered && (${#COMPREPLY[@]}>0 || (!(default || bashdefault) && (dirnames || plusdirs))))); then onlydirs=1; fi
    while IFS= read -r -d '' match; do fileMatches+=("$match"); done < <(
      shopt -s nullglob
      search=$cur
      [[ $search == '~/'* ]] && search=$HOME/${search:2}
      for match in "$search"*; do
        [[ -e $match || -L $match ]] || continue
        ((onlydirs)) && [[ ! -d $match ]] && continue
        [[ $cur == '~/'* ]] && match="~/${match:${#HOME}+1}"
        printf '%s\0' "$match"
      done
    )
  fi
fi
functionCount=${#COMPREPLY[@]}
COMPREPLY+=("${fileMatches[@]}")
quote_word() {
  local value=$1 prefix=
  if [[ $value == '~/'* ]]; then prefix='~/'; value=${value:2}; fi
  if [[ -z $value ]]; then REPLY="$prefix''"
  elif [[ $value =~ ^[a-zA-Z0-9_./:+,@%=-]+$ ]]; then REPLY=$prefix$value
  else value=${value//\'/\'\\\'\'}; REPLY="$prefix'$value'"; fi
}
labels=() inserts=() common= count=0 candidate=0
if ((BASH_VERSINFO[0]>=4)); then declare -A seen; fi
for match in "${COMPREPLY[@]}"; do
  file=$filenames; ((candidate>=functionCount)) && file=1; ((candidate++))
  [[ -n $match ]] || continue
  suffix=' '; ((nospace)) && suffix=
  if (( !file && nospace )) && [[ $match == *' ' ]]; then match=${match% }; suffix=' '; fi
  check=$match; [[ $check == '~/'* ]] && check=$HOME/${check:2}
  if ((file)) && [[ -d $check ]]; then match=${match%/}/; suffix=; fi
  if ((BASH_VERSINFO[0]>=4)); then
    [[ ${seen["$match"]-} ]] && continue
    seen["$match"]=1
  fi
  if ((count==0)); then common=$match; else
    while [[ $match != "$common"* ]]; do common=${common%?}; done
  fi
  if ((count<200)); then
    quote_word "$match"
    labels+=("$match"); inserts+=("$REPLY$suffix")
  fi
  ((count++))
done
if [[ -n $common ]]; then
  at=$((${#common}-1))
  printf -v byte '%d' "'${common:at:1}"
  while ((at>0 && byte>=128 && byte<192)); do ((at--)); printf -v byte '%d' "'${common:at:1}"; done
  need=1
  if ((byte>=194 && byte<=223)); then need=2
  elif ((byte>=224 && byte<=239)); then need=3
  elif ((byte>=240 && byte<=244)); then need=4; fi
  ((${#common}-at<need)) && common=${common:0:at}
fi
if [[ -n $common ]]; then quote_word "$common"; common=$REPLY; fi
((count)) || common=
printf '%s\0' "$from" "$to" "$common" "$count"
for ((i=0;i<count && i<200;i++)); do printf '%s\0' "${labels[i]}" "${inserts[i]}"; done
