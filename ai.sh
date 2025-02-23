#!/usr/bin/bash


if [ -f ~/.airc ]; then
    source ~/.airc
fi
if [ -z "$CEREBRAS_API_KEY" ]; then
    echo "Please set CEREBRAS_API_KEY environment variable"
    exit 1
fi
hs=~/.ai_history
hp=~/.ai_chat
if [ ! -s $hs ]; then
    echo '{"role":"system","content":""}' > $hs
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
        IFS=$'\n' read -r -e -p "|vi|> " what
        if [ "$what" == "" ]; then
            continue
        fi
        if [[ "$what" =~ ^/system[[:blank:]]+(.*)$ ]]; then
            echo '{"role":"system","content":"'${BASH_REMATCH[1]}'"}' > $hs
            continue
        fi
        if [ "$what" == "/exit" -o "$what" == "/quit" ]; then
            break
        fi
        if [ "$what" == "/clear" ]; then
            echo '{"role":"system","content":""}' > $hs
            continue
        fi
        if [ "$what" == "/history" ]; then
            cat $hs
            continue
        fi
        if [ "$what" == "/debug" ]; then
            DEBUG=1
            continue
        fi
        if [ "$what" == "/nodebug" ]; then
            DEBUG=0
            continue
        fi
        if [ "$what" == "/help" ]; then
            echo "/exit, /quit, /clear, /history, /help, /debug, /nodebug, /system"
            continue
        fi
        history -s "$what"
        crbrs_chat_completion "$what"
    done
    history -w $hp
}

crbrs_chat
