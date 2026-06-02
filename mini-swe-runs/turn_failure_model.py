"""Custom litellm model for mini-swe-agent: timeouts and max-token truncations
become FAILED TURNS the agent recovers from, instead of retry storms or dead
episodes.

Why: the endpoint sometimes enters runaway repetition loops (greedy-decoding
attractors). A timed-out request would normally be retried 10x by mini's
tenacity wrapper — and since the loop is conversation-state-dependent, the
retries tend to run away too, grinding ~450s x 10 per step before killing the
whole instance. Instead we:

  * Timeout            -> no retry; append a corrective user message and let
                          the agent take its next turn.
  * finish_reason=length (max_tokens truncation) -> drop the truncated
                          assistant text entirely (keeps loop garbage out of
                          subsequent prompts) and append a targeted "you were
                          truncated, don't repeat yourself" message instead of
                          the generic "No tool calls found" error.

Other API errors (5xx, connection resets) still retry as before — transient
infra blips should not fail turns.

Wired up via model.yaml:  model.model_class: turn_failure_model.TurnFailureModel
(run scripts put this directory on PYTHONPATH so uvx's python can import it).
Both raised FormatErrors count against step_limit, and wall_time_limit_seconds
still bounds the episode, so failure spirals stay bounded.
"""

import litellm

from minisweagent.exceptions import FormatError
from minisweagent.models.litellm_model import LitellmModel

_RETRY_HINT = (
    "Do not repeat yourself. Respond concisely and include exactly one bash "
    "tool call with the next command to run."
)


class TurnFailureModel(LitellmModel):
    # Timeout aborts the tenacity retry loop immediately (reraised as-is),
    # then query() below converts it into a failed turn.
    abort_exceptions = LitellmModel.abort_exceptions + [litellm.exceptions.Timeout]

    def query(self, messages: list[dict[str, str]], **kwargs) -> dict:
        try:
            return super().query(messages, **kwargs)
        except litellm.exceptions.Timeout:
            raise FormatError(
                {
                    "role": "user",
                    "content": (
                        "Your previous response timed out before it finished "
                        "generating and was discarded. " + _RETRY_HINT
                    ),
                    "extra": {"interrupt_type": "Timeout"},
                }
            ) from None

    def _parse_actions(self, response) -> list[dict]:
        # Raised from inside query() before the assistant message is built, so
        # the truncated (often loop-degenerate) text never enters the
        # conversation — only the corrective user message below does.
        if (response.choices[0].finish_reason or "") == "length":
            raise FormatError(
                {
                    "role": "user",
                    "content": (
                        "Your previous response exceeded the maximum generation "
                        "length and was truncated and discarded. " + _RETRY_HINT
                    ),
                    "extra": {"interrupt_type": "MaxTokens"},
                }
            )
        return super()._parse_actions(response)
