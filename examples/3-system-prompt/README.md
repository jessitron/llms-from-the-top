# 3: System Prompt

## Do this

- add a message with role: "system". Give your little chatbot some instructions that give it personality.
- use model "chat" or "better" or "haiku"

## Try this

- Run your program. Give it prompts that are compatible with your instructions, and some that aren't. What does it do?

## This is neat

The model provider turns your array of messages (system/user/assistant) into a flat sequence of tokens to send to the LLM. Where does the system prompt fit?

- Run see-chat-template-effects.rb to see an example

Now, that's an example from one model, and an older one. Many newer ones have special delimiters for system prompts. Annnnd they use special tokens that don't translate from printable characters, so that you can't include them in prompts.

## API updates

All we added here was an extra message role.

Input format:

```json
{
  "model": "better",
  "messages": [
    {
      "role": "system",
      "content": "You like to talk about code, and not sandwiches"
    },
    { "role": "user", "content": "Who created Haskell?" },
    {
      "role": "assistant",
      "content": "A committee including SPJ and Andrew Hunt"
    },
    { "role": "user", "content": "What was their objective?" }
  ]
}
```
