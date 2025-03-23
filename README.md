# AI Chat CLI

## Description

`ai.pl` is a command-line interface for interacting with an AI chat model.


## Development prerequisites

```
sudo apt install libjson-xs-perl libterm-readline-gnu-perl libjson-perl libwww-curl-perl
```

## Build

```
docker buildx build --load --tag ai .
```

## Run

```
docker run -v ai:/ai -v ~/.airc:/ai/.airc --rm -it ai
```

## Usage

```
ai.pl [options]
```

### Options

- `-help` : Print a brief help message and exits.
- `-debug` : Enable debug mode.

### Environment Variables

- `AI_DIR` : Base directory for AI configuration and data files.
- `AI_CONFIG` : Path to the AI configuration file.
- `DEBUG` : Enable or disable debug mode.
- `AI_PROMPT` : Prompt string for the AI chat.
- `AI_CEREBRAS_API_KEY` : API key for accessing the Cerebras AI API.
- `AI_MODEL` : Model name for the AI chat.
- `AI_TOKENS` : Maximum number of tokens for the AI chat completion.
- `AI_TEMPERATURE` : Temperature setting for the AI chat completion.
- `AI_CLEAR` : Clear the chat status file if set.
