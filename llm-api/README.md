# LLM API for use in the workshop

For this workshop, participants will write a baby agent. For that, they need a model. For that, there is this API that they can call.

## Architecture

The API composed here is OpenAI-compatible, since that's a standard.

It starts with /v1/completions, so we can see how a base model responds.

and then we can move to /v1/chat/completions later, maybe. Maybe we'll keep using /completions and put the template on the agent side, for clarity of what's happening!

## Deployment

I'm planning to use Modal.com because it will let me run a pretrained model on its infrastructure.

## Telemetry

This app uses (will use) OpenTelemetry to send data to Honeycomb.
