#!/usr/bin/env bash
# tavus-dev.sh — utility per gestire le conversazioni Tavus durante lo sviluppo.
# Richiede: TAVUS_API_KEY nell'ambiente, jq installato.
# Uso: bash tavus-dev.sh <comando> [arg]

API="https://tavusapi.com/v2/conversations"
H=(-H "x-api-key: $TAVUS_API_KEY" -H "Content-Type: application/json")

case "$1" in
  # Lista tutte le conversazioni attive (id + nome)
  list)
    curl -s "$API?status=active&limit=100" "${H[@]}" \
      | jq -r '.data[] | "\(.conversation_id)  \(.conversation_name)"'
    ;;

  # Chiudi una conversazione specifica: bash tavus-dev.sh end <conversation_id>
  end)
    curl -s -X POST "$API/$2/end" "${H[@]}" | jq '.'
    ;;

  # Chiudi TUTTE le conversazioni attive (sblocca lo slot)
  kill-all)
    for id in $(curl -s "$API?status=active&limit=100" "${H[@]}" | jq -r '.data[].conversation_id'); do
      echo "ending $id"
      curl -s -X POST "$API/$id/end" "${H[@]}" > /dev/null
    done
    echo "done."
    ;;

  # Crea una conversazione di test in italiano, con auto-chiusura a 2 minuti
  test-it)
    curl -s -X POST "$API" "${H[@]}" -d '{
      "persona_id": "pa0df2701ff0",
      "replica_id": "rf4e9d9790f0",
      "conversation_name": "dev-test-it",
      "properties": { "language": "italian", "max_call_duration": 120 }
    }' | jq -r '.conversation_url'
    ;;

  *)
    echo "Usage: bash tavus-dev.sh {list|end <id>|kill-all|test-it}"
    ;;
esac