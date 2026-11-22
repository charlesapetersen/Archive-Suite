# 15. Whether a route's provider may train on the pages (W46.training-optout)

Owner review of the pipeline doc, 2026-11-17: many users care whether their uploads can be used to train a provider's
models. This note records each way the app sends pages off the Mac, what the provider's own terms say, and the source.
The app's copy is `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Settings/SettingsTraining.swift`; the two must match,
and a change in a provider's terms is made in both.

Read 2026-11-17, from the providers' pages (searched and quoted, not a lawyer's reading). Terms change; a session that
touches a provider's route checks its row again.

## The rule

The collection interview's switch **"My pages must not train a provider's models"** (`noTraining`, any layer, off by
default; `SPEC/collection-settings.md`) hides every route that is not **never** below, for the ways this user would
send it:

- the ways counted are the keys and plans the user has; a route the user cannot reach counts every way it names;
- a route reachable by two ways is hidden if either may train, since the app may use either;
- a cascade is as safe as its least safe reader;
- an OpenRouter row's provider is its own `app_route` pin; a row of another stage sharing a reading row's id is unpinned;
- a route on this Mac, done by hand, or run on the user's own cluster sends nothing to a provider.

"Free use trains, paid does not" and "a personal plan trains unless switched off" are hidden too: the app cannot tell
whether a key is billed or whether a plan's setting is off. Each stage card then says what the switch costs: the best
route it hides (one kept out by the switch alone), that route's figure against the pick's, both prices per 1,000, and
whose terms hide it.

## Keys

| way | terms | what they say | source |
|---|---|---|---|
| Stanford AI API Gateway (`gateway`) | never | No data sent through the gateway is used to train models; UIT has agreements with the vendors on training and retention, logs calls but not their content, and the gateway is approved for High Risk data. | https://uit.stanford.edu/service/ai-api-gateway/faqs |
| Anthropic API key (`anthropic`) | never | The 2025 consumer-terms change (training on Free, Pro, Max) does not apply to services under the Commercial Terms, API use included, also through Bedrock and Vertex. | https://www.anthropic.com/news/updates-to-our-consumer-terms |
| OpenAI API key (`openai`) | never | By default OpenAI does not use API Platform inputs and outputs to train its models; only an account that joins its data-sharing programme is trained on. That is an opt-in the user made, unlike a free tier, which is a default, so the key counts as never. | https://help.openai.com/en/articles/5722486-how-your-data-is-used-to-improve-model-performance |
| Gemini API key (`gemini`) | unless paid | Unpaid Services (AI Studio, the free quota) are used to improve Google's products and machine learning, with human review; Paid Services are not. In the EEA, Switzerland and the UK the paid terms hold for free use too. | https://ai.google.dev/gemini-api/terms |
| Mistral API key (`mistral`) | unless paid | The free Experiment tier trains on API traffic by default (opt-out in Admin ▸ Privacy); pay-as-you-go and enterprise accounts are opted out by default. | https://help.mistral.ai/en/articles/455207-can-i-opt-out-of-my-input-or-output-data-being-used-for-training |

## Plans (the Local Agent backend: `claude -p`, `codex exec`)

| way | terms | what they say | source |
|---|---|---|---|
| Claude Free, Pro, Max (`claude`) | unless opted out | Since 2025-08-28 Anthropic trains on consumer chats and Claude Code sessions when the account allows it (the "Help improve Claude" choice), with five-year retention; off, 30 days. | https://www.anthropic.com/news/updates-to-our-consumer-terms |
| ChatGPT Free, Plus, Pro (`chatgpt`) | unless opted out | Individual plans may be used to train unless "Improve the model for everyone" is off; that setting covers Codex tasks too. Business, Enterprise and Edu are not trained on. | https://help.openai.com/en/articles/7730893-data-controls-in-chatgpt |

## OpenRouter

OpenRouter itself keeps no prompts unless the account opts in to logging, and does not train on them; the training
question is the upstream provider's (https://openrouter.ai/docs/guides/privacy/data-collection,
https://openrouter.ai/docs/guides/privacy/provider-logging). The app pins each OpenRouter model to one upstream
(`OpenRouterRoute.catalog`, `allow_fallbacks: false`), so the upstream's terms are the route's:

| upstream | used by | terms | what they say | source |
|---|---|---|---|---|
| DeepInfra | Qwen3-VL 235B, Qwen3.5 9B | never | Inference inputs are held in memory only, not stored, and not used for training (except Google and Anthropic models it resells, whose makers' terms apply). | https://deepinfra.com/docs/data |
| Alibaba Cloud | Qwen3.8 Flash | never | Model Studio "will never use your data for model training". | https://www.alibabacloud.com/help/en/model-studio/privacy-notice |
| Z.ai | GLM-5.3 Flash | never | The API's data processing addendum: content is processed in real time and not stored; the consumer policy's training use covers individual users, not the API. | https://docs.z.ai/legal-agreement/privacy-policy |
| Chutes | Qwen3.6 27B | may train | OpenRouter serves Chutes (decentralised, on Bittensor) only to accounts that enable model training in their privacy settings. Chutes' own policy now says prompts are not stored, but the nodes are independent operators. | https://x.com/OpenRouterAI/status/1889732807481561112 |
| a closed model's maker (Google, OpenAI) | Gemini and GPT rows reached with an OpenRouter key | never | OpenRouter reaches the maker's paid API, whose paid terms rule out training. | as the keys above |
| Mistral, unpinned | Mistral rows reached with an OpenRouter key | unknown, hidden | Mistral's models are open-weight, so OpenRouter may serve them from third parties; the app pins none of them. | — |
| no upstream pinned | OpenRouter rows without an app route | unknown, hidden | Whose terms apply is not known. | — |

OpenRouter also takes `provider.data_collection: "deny"` on a request, which routes only to providers that do not
collect data; with a pinned provider and no fallbacks, a request to one that does would fail rather than go elsewhere.
The app sends it on the requests for a job whose collection has the switch on (`OpenRouterDataPolicy`). A call
pinned to Chutes fails for that job. Concurrent jobs use their own collection settings. Unpinned routes always send
the deny (W49.proc-training-deny-per-job).

## The user's answers and the run (W46.training-optout-run)

The general interview asks, for each key and plan found whose terms depend on the account, whether it trains
(`trainingOff`: `key:gemini` billed, `key:mistral` paid or opted out, `plan:claude` and `plan:chatgpt` with the
training setting off); an answered way counts as never. "May train" and "unknown" cannot be answered away.
Process Files' Start also counts two ways the solver's table lacks: the Gemini CLI (the Local Agent's third tool),
which signs in with a personal Google account whose free use Google may train on
(https://developers.google.com/gemini-code-assist/resources/privacy-notice-gemini-code-assist-individuals), so may
train, unanswerable; and a gateway other than Stanford's, whose terms are unknown.

## Not in the app's routes

Azure Document Intelligence, AWS Textract and Google Document AI are bench checks only; their cloud terms do not train
on customer content, but no app route reaches them, so they have no row in the Swift table.
