# 4: Tools

Now it's time to make our chatbot into an agent, by giving it fingers.

First, let's give it a way to look around.

## Do This

Add to the system prompt some instructions that it should reply with LISTFILES to get a list of files available, and READFILE <filename> to read one of them.

Then when it provides a response, check it for LISTFILES or READFILES. If you find one, execute the operation and return the output to the LLM _instead of asking the user for more input_.

Example: vort_4a.rb

## Try This

Ask your agent "What files are here?"

Try it with the models "chat" ... it might work. You have to be super forgiving with its formatting of the tool call (like, I look for anything containing LISTFILES), because it isn't trained for this.

Try it with the model "better" ... it might work. That model is trained for tool calls. However, it's trained for a specific formatting of them!

## Do This

1. Instead of putting tool call specs in the system prompt, add this to every API request, alongside `model` and `messages`:

```json
tools: [
  { type: "function", function:
    { name: "list_files",
      description: "List files in the current directory",
      parameters: { type: "object", properties: {} }
    }
  },
  { type: "function", function:
    { name: "read_file",
      description: "Read a file's contents",
      parameters: { type: "object", properties: { path: { type: "string", description: "path to the file" } }, required: ["path"] }
    }
  }
]
```

2. Look for `[TOOL_CALLS\]list_files` and `[TOOL_CALLS\]read_file.*"path":` in the response. (You probably want to skip implementing this but it's an interesting stage to look at)

Example: vort_4b.rb

3. Use the model "better"

The tool calls get concatenated into the input according along with user/assistant message as part of the chat template. (Technically, Mistral moved beyond a jinja template and there's a whole library that the inference server has to use to get from the /chat/completions API format to a string of input.)

The output comes back as text and can be parsed into tool calls.

## Try This

Now run vort and see if it works. `What files are here?`

This "better" model is tool-called trained and should figure it out.

## Do This

OK now let's fully use the /chat/completions API format.

To do that, we move to a real model provider. Use "nano" and my endpoint will route to the smallest model offered by OpenAI.

2. Look for `"tool_calls"` in the response. Now you don't have to do parsing.

Example: vort_4c.rb

## Try this

Use "haiku" or "nano" as the model there, and it should happily look at files.

## Do this

Now let's add some tool calls that let the agent affect the world!

3. Add a tool for writing the content of a file. (I'm not trying to be efficient here)

Example: vort_4d.rb

## Try this

In this folder, go to test-sort/workspace, and run your coding assistant there. Use model "nano"

```
cd test-sort/workspace
MODEL=nano ../../vort_4d.rb
```

Ask it to fix the sort. `Hey, can you fix my sort?`

You might have to convince it to use its tools, it can get surly.

🐣 My system prompt tells it to refuse to do non-coding tasks. Take that line out and "nano" and "luna" will behave better. Different models need different prompts!

After it tries, run `test.pl` to see whether it succeeded. Sometimes it does, sometimes not. "haiku" succeeds most of the time.

## Do this

Give it a way to test! Add a tool that runs a shell command and returns the output.

Example: vort_4e.rb

(I also changed the system prompt there so that luna and nano would stop being lazy)

Try again to ask one of the small models to fix it. It has a better chance now! Haiku will succeed consistently.

## API expansion

We can send tool definitions and receive tool calls and provide tool call results in a structured way.

They all get flattened into strings(\*) and then tokens before they go to the LLM, and the LLM is trained to understand the particular ones it receives.

(\*) technically some tokens used to delimit system prompt, tool call results etc are not translated from strings. It's all tokens when it gets fed in, some of them are special now. This helps make prompt injection less effective.

### Input Format

TODO: document the /chat/completions API including tool definitions and tool results

### Output Format

TODO: document its output including tool calls
