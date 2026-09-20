# Step 1: Completions

LLMs are completion machines. Given some text input, they choose something to come next. Unless specifically trained otherwise, the continue the text with some text that's likely to follow it.

LLMs that are assistant-trained know how to answer questions.

**Warning: safeguards not included. pretrained LLMs provide raw predictions based on the content of the internet. They can be horrible.**

## Do these things

- Write a program that
  - accepts text on stdin
  - sends it to the workshop's completions API, and
  - prints the returned text to STDOUT.

- Run the program several times; give it different input. Try things like:
  - Once upon a time, a giant
  - Join us for
  - What is the capital of Georgia?
  - d

The model should continue from there.

The default model at my API is a base model, Mistral-7B, which is 

## Now make it chat

To make it answer questions, we use a different model. One trained for chat. 

- Change the model from "base" to "chat" 

## Workshop Completions API

URI: https://llms-from-the-top.jessitron.com/v1/completions

HTTP headers:

- `content-type: application/json`
- `x-api-key: exploreddd`

Input format (JSON body):

```json
{ "model": "base", "prompt": "Once upon a time, a giant" }
```

- `model` — "base" or "chat". Defaults to "chat" if omitted.
- `prompt` — the text to continue.
- `max_tokens` — optional, defaults to 100.

Output format (JSON body, vLLM's OpenAI-compatible completions response):

```json
{
  "choices": [
    { "text": " ...continuation...", "finish_reason": "stop" }
  ]
}
```

- `choices[0].text` — the completion.
- `choices[0].finish_reason` — why it stopped, e.g. "stop" or "length".
