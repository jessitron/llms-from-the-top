# Step 2: Assistant-trained

## Do This

1. Put a loop around your program:
   - receive input
   - check it for an exit condition
   - send the input to the LLM
   - print the output

Example: vort_2a.rb

We're using model: "chat"

## Try This

Run your little chatbot. Ask it a question, then a follow-up question.

like "What is the capital of France?" and then "What industries are strong there?"

See it get confused on the follow-up question. It has no context!

## Do This

For continuity, we have to send the LLM the entire context every time.

2. Accumulate all user instructions, keep them in one prompt. Each one is in `[INST] [/INST]`

3. Also put everything the LLM sent back in that prompt! It doesn't get square-bracket delimiters. But _do_ but an ending token after it, representing that the LLM chose to stop. `</s>` is the one for our "chat" model.

Example: vort_2b.rb

## Try This

Now run your chatbot. Ask it a question and a follow-up question.

It should know what it's talking about!

## Now we can make it prettier

Those `[INST]` delimiters are specific to this model, and nobody wants to send those. Nobody uses the `/v1/completions` endpoint anymore. Instead, we use the `/v1/chat/completions` API. Then the model provider

Example: vort_2c.rb

The new API looks like OpenAI's chat completions API. (The [full API reference](https://developers.openai.com/api/reference/resources/chat) is huge. My endpoint doesn't support it all, and some models on my endpoint support more than others.)

URI: https://llms-from-the-top.jessitron.com/v1/chat/completions

Method: POST

Headers:

```
content-type: application/json
x-api-key: <ask Jess for it>
(optional) x-conversation-id: <your unique ID for this agent run>
(optional) user-agent: <your name>
```

Input format:

```json
{
  "model": "better",
  "messages": [
    { "role": "user", "content": "What is the capital of France?" },
    { "role": "assistant", "content": "Paris" },
    { "role": "user", "content": "What is it famous for?" }
  ]
}
```

`model` is optional; it defaults to `"chat"`. Other valid values: `"base"`, `"better"`.

Output format:

```json
{
  "choices": [
    {
      "message": { "role": "assistant", "content": "..." }
    }
  ]
}
```
