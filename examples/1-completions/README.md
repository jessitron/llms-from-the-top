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

//TODO: agent, please fill in

URI: https://llms-from-the-top.jessitron.com/v1/completions

HTTP headers:

Input format:

Output format:
