/**
 * Front door for llms-from-the-top.jessitron.com.
 *
 * Today this just proxies everything straight through to the Modal-hosted
 * vLLM server. It's the seam where request-level logic (x-api-key auth,
 * base-vs-trained model routing by header) gets added later — see the yaks
 * nested under "custom domain" in this repo's `yx list`.
 */
export default {
  async fetch(request, env) {
    const incoming = new URL(request.url);
    const upstream = new URL(env.BACKEND_URL);
    upstream.pathname = incoming.pathname;
    upstream.search = incoming.search;

    const upstreamRequest = new Request(upstream, request);
    upstreamRequest.headers.set("host", upstream.hostname);
    return fetch(upstreamRequest);
  },
};
