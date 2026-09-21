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

Those `[INST]` delimiters are specific to this model, and nobody wants to send those. Nobody uses the `/v1/completions` endpoint anymore.

Example: vort_2c.rb

The new API, as standardized by OpenAPI (TODO: link)

URI: https://llms-from-the-top.jessitron.com

Method: POST

Headers:

TODO

Input format:

TODO

Output format:

TODO
