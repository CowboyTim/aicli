#!/usr/bin/bash


if [ -f ~/.airc ]; then
    source ~/.airc
fi
if [ -z "$CEREBRAS_API_KEY" ]; then
    echo "Please set CEREBRAS_API_KEY environment variable"
    exit 1
fi
hs=~/.ai_chat_status_${AI_PROMPT:-default}
hp=~/.ai_history_${AI_PROMPT:-default}
pr=~/.ai_prompt_${AI_PROMPT:-default}
if [ ! -s $hs -o "${AI_CLEAR:-0}" = 1 ]; then
    if [ -f $pr ]; then
        prompt=$(<$pr)
        echo '{"role":"system","content":'$(echo -n "${prompt}" | jq -RsaMj .)'}' > $hs
    else
        echo '{"role":"system","content":""}' > $hs
    fi
fi

function crbrs_chat_completion(){
    s=$*
    s=$(echo -n "$s" | jq -RsaMj .)
    echo '{"role":"user","content":'$s'}' >>$hs
    jstr=$(<$hs)
    jstr=${jstr//$'\n'/,}
    [ "$DEBUG" == 1 ] && echo "[$jstr]" | jq -r >/dev/stderr
    response=$(curl -qsSkL 'https://api.cerebras.ai/v1/chat/completions' \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${CEREBRAS_API_KEY}" \
        --data '{
          "model": "llama-3.3-70b",
          "max_tokens": 8192,
          "stream": false,
          "messages": ['"${jstr}"'],
          "temperature": 0,
          "top_p": 1
        }')
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get response from API" >&2
        return 1
    fi
    [ "$DEBUG" == 1 ] && { echo "$response" | jq -r >/dev/stderr; }
    resp=$(echo "$response" | jq -r '.choices[0].message.content')
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse response" >&2
        return 1
    fi
    echo "$resp"
    s=$(echo -n "$resp" | jq -RsaMj .)
    echo '{"role":"assistant","content":'$s'}' >>$hs
}

function crbrs_chat(){
    history -r $hp
    set -o vi
    while true; do
        ai_prompt='|chat'
        what=()
        do_exit=
        do_continue=
        system_prompt='|> '
        chat_prompt=""
        while true; do
            line=
            if [ -t 0 ]; then
                chat_prompt="$ai_prompt$system_prompt"
                IFS=$'\n' read -r -e -p "$chat_prompt" line
                if [ $? -ne 0 ]; then
                    do_exit=1
                    break
                fi
            else
                if [ ${AI_SILENT:-1} -eq 1 ]; then
                    chat_prompt=""
                else
                    chat_prompt="$ai_prompt$system_prompt"
                fi
                line=$(< /dev/stdin)
                if [ -z "$line" ]; then
                    do_exit=1
                    break
                else
                    what+=($line)
                    break
                fi
            fi
            if [ -z "$line" ]; then
                break
            fi
            if [[ "$line" =~ ^/system  ]]; then
                history -s "$line"
                ai_prompt="|system"
                what+=($line)
                continue
            else
                ai_prompt=""
            fi
            if [ "$line" == "/exit" -o "$line" == "/quit" ]; then
                history -s "$line"
                do_exit=1
                break
            fi
            if [ "$line" == "/clear" ]; then
                history -s "$line"
                echo '{"role":"system","content":""}' > $hs
                do_continue=1
                break
            fi
            if [ "$line" == "/history" ]; then
                history -s "$line"
                cat $hs
                do_continue=1
                break
            fi
            if [ "$line" == "/debug" ]; then
                history -s "$line"
                DEBUG=1
                do_continue=1
                break
            fi
            if [ "$line" == "/nodebug" ]; then
                history -s "$line"
                DEBUG=0
                do_continue=1
                break
            fi
            if [ "$line" == "/help" ]; then
                history -s "$line"
                echo "/exit, /quit, /clear, /history, /help, /debug, /nodebug, /system"
                do_continue=1
                break
            fi
            what+=($line)
        done
        if [ -n "$do_exit" ]; then
            break
        fi
        if [ -n "$do_continue" ]; then
            continue
        fi
        what=$(echo "${what[@]}")
        [ "$DEBUG" == 1 ] && echo "WHAT: $what" >/dev/stderr
        if [ "$what" == "" ]; then
            continue
        fi
        history -s "$what"
        if [[ "$what" =~ ^/system[^$]*$ ]]; then
            what="${what#/system}"
            echo '{"role":"system","content":'$(echo -n "${what}" | jq -RsaMj .)'}' > $hs
            continue
        fi
        crbrs_chat_completion "$what"
    done
    history -w $hp
}

crbrs_chat
