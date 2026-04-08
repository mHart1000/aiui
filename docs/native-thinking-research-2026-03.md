# Native Thinking Stream Research - March 2026

## Executive Summary

Attempted to integrate Qwen 3.5's native chain-of-thought reasoning output (displayed via `<think>` tags in CLI) into the app's streaming interface. After extensive debugging, concluded the infrastructure isn't mature enough for stable production use.

**Status**: Paused pending ecosystem maturity  
**Date**: March 13-14, 2026  
**Model Tested**: Qwen 3.5 35B (via llama.cpp/llama-server)

---

## Background

### What We Were Trying To Achieve

Qwen 3.5 has native chain-of-thought reasoning capability. When run via `llama-cli`, it displays thinking process like:

```
Thinking Process:

1. Analyze the input...
2. Consider different approaches...
3. Draft potential responses...

</think>

[Final answer here]
```

**Goal**: Capture this native thinking in the app's collapsible thinking section when scaffolding is OFF, instead of using our custom two-pass system.

**Why**: 
- Let reasoning models use their built-in capabilities
- Simpler than custom scaffolding for models designed for CoT
- Potentially better reasoning quality from native implementation

---

## Technical Findings

### The Format Problem

**Inconsistent Output Formats Observed:**

1. **CLI Mode** (llama-cli):
   - Uses plaintext header: `Thinking Process:`
   - Numbered reasoning steps
   - Closes with `</think>` tag ONLY (no opening tag)

2. **Server Mode with System Prompt**:
   - Sometimes generates `<think>` opening + `</think>` closing
   - Sometimes just `</think>` closing
   - Sometimes uses `<thinking>` opening + `</think>` closing (mixed)
   - **Often**: All thinking content arrives before streaming starts

3. **Varies By Question Complexity**:
   - Simple questions: Model skips thinking entirely
   - Complex questions: More consistent (but still unreliable)

### The Streaming Problem

**Root Cause**: llama-server's OpenAI-compatible API buffers fast content

**Observed Behavior**:
```
Stream chunk 1: "</think>"  ← Thinking already finished!
Stream chunk 2: "\n\nEstimates vary..."  ← Already on final answer
```

**What's Happening**:
1. Model generates thinking content very quickly (high tokens/sec)
2. llama-server buffers until a certain threshold
3. By the time HTTP SSE stream starts, thinking section is complete
4. First chunk received is the closing tag
5. All thinking content was never sent over the wire

**CLI vs Server Difference**:
- `llama-cli`: Raw token-by-token output, sees everything
- `llama-server`: OpenAI API compatibility layer adds buffering
- No control over buffering behavior with current llama.cpp versions

---

## Approaches Attempted

### Attempt 1: Tag Detection and Parsing
**Implementation**: Detect `<think>`, `<thinking>`, `</think>`, `</thinking>` tags in stream

**Result**: Worked occasionally when tags appeared in stream, but:
- Opening tags often never received (buffered before stream)
- Closing tag appeared first
- Partial tag detection added complexity

**Code Location**: `app/services/chat_service.rb` (single_pass_call)

---

### Attempt 2: "Thinking Process:" Header Detection
**Implementation**: Also detect plaintext "Thinking Process:" header

**Result**: Still failed due to buffering - header never appeared in stream

---

### Attempt 3: Orphaned Tag Fallback
**Implementation**: When closing tag appears without opening:
1. Break from streaming
2. Make non-streaming API call
3. Parse full response
4. Manually yield thinking and response sections

**Result**: 
- ✅ Could recover thinking content
- ❌ Lost real-time streaming
- ❌ Made two API calls (inefficient)
- ❌ Still unreliable - model format varies

---

### Attempt 4: Stronger System Prompts
**Implementation**: Explicit system prompt with examples:

```
ALWAYS structure your responses in this exact format:

<think>
[Your reasoning here]
</think>

[Final answer]
```

**Result**: Model ignored instructions 80% of the time, especially on simple questions

### The System Prompt Paradox

**Discovery**: Forcing tags via system prompts conflicts with native reasoning

**Two Layers of Behavior**:
1. **Native Weights**: Model trained to naturally emit reasoning chains
2. **System Instruction**: Runtime commands to use specific tags

**The Conflict**:
- When you explicitly ask for `<think>` tags, model complies as a *writer*, not as a *reasoner*
- This produces "fake" thinking that's shorter and lower quality
- The model wants to think naturally but doesn't necessarily want specific HTML-style tags
- System prompts are a "soft override" that fights the "hard" internal training

**Result**: Can't reliably force the behavior with prompts - needs infrastructure support

---

## Infrastructure Limitations

### llama-server Issues
1. **No streaming control**: Can't adjust buffering behavior
2. **OpenAI API only**: Can't access raw token stream
3. **No server-side settings** for thinking/reasoning modes
4. **Unclear roadmap** for CoT streaming support
5. **Special token filtering**: `<think>` tags treated as special tokens (like `<|endoftext|>`) and filtered from output
6. **Chat template mismatch**: Server not using correct Qwen/ChatML template for reasoning state
7. **Missing parameters**: `enable_thinking` Jinja template parameter not being passed correctly

### llama.cpp Ecosystem
- Native CoT support is very new (late 2025/early 2026)
- Designed for CLI use primarily
- Server mode not optimized for this workflow
- Community still figuring out best practices
- **Active regression (March 2026)**: Recent builds (b8227+) introduced auto-parser that breaks reasoning tags
- **In transition**: Moving from text tags to dedicated `reasoning_content` JSON field (OpenAI spec alignment)
- **New flags available**: `--reasoning-budget`, `--jinja`, `--chat-template` (late Feb 2026)
- **Template issues**: Qwen models require specific `qwen` or `chatml` templates for special token handling

### Model Behavior
- Qwen 3.5's thinking format isn't standardized
- Depends heavily on prompt engineering
- No official guidance on think tag usage
- Format differs between model versions
- **Dynamic entry**: Uses "Hybrid Thinking/Non-Thinking" architecture
- **Adaptive reasoning**: Model trained NOT to think on simple questions (by design)
- **Gated DeltaNet**: Complex internal state harder for inference servers to serialize into text tags
- **Native vs Forced**: Quality degrades when thinking is forced via system prompts vs native weights

---

## What Works: Two-Pass Scaffolding

**Current Working Solution**: Our custom two-pass system

**How It Works**:
1. Pass 1: Ask model to analyze and plan (planning phase)
2. Pass 2: Use that analysis to generate final response
3. Both streamed separately to thinking/response sections

**Advantages Over Native Tags**:
- ✅ 100% reliable streaming
- ✅ Consistent format across all models
- ✅ Full control over behavior
- ✅ Works with any model (not just Qwen)
- ✅ Better separation of concerns
- ✅ Predictable UX

**User Control**:
- Toggle scaffolding ON: Use two-pass (reliable, slower)
- Toggle scaffolding OFF: Direct response (fast, no thinking)

---

**Watch For**:
1. llama.cpp updates with CoT streaming support
2. Qwen model updates with standardized thinking format
3. Community best practices emerging
4. Other inference servers (vLLM, TGI) adding native support
5. **OpenAI spec alignment**: `reasoning_content` field in JSON responses (estimated May 2026)
6. **Template stability**: Fixed Jinja templates for Qwen reasoning state
7. **Build stability**: Regression fixes for auto-parser issues (post-b8227)

**Triggers to Revisit**:
- llama-server adds `--thinking-mode` or similar flag
- Qwen releases official thinking format spec
- Major inference servers standardize on CoT streaming
- Multiple successful implementations documented publicly
- **`reasoning_content` field becomes standard in llama.cpp OpenAI endpoint**
- **DeepSeek R1 implementation patterns can be applied to Qwen**

**Alternative for Testing**:
- **DeepSeek R1**: Known for "rock-solid" consistent thinking tags as of March 2026
- If UI testing needed, DeepSeek R1 provides stable baseline for thought separation
- Qwen implementation should match R1 patterns once infrastructure matures

---

### Long Term Vision
**Ideal State**: Native thinking "just works"

**Requirements**:
1. **Standardized format** across reasoning models
2. **Server support** for thinking token streaming
3. **Model consistency** in using format
4. **Documentation** and community patterns

**Potential Approaches When Ready**:
- Model-specific adapters with format handling
- Inference server settings for CoT modes
- Standardized SSE event types for thinking vs response
- Fallback strategies when detection fails

---


## Conclusion

Native thinking tag support is **theoretically possible** but **practically unstable** with current infrastructure (March 2026). The existing two-pass scaffolding system provides reliable thinking output with better UX control.

**Multiple sources confirm** the infrastructure is in active transition with known regressions. Any tag-parsing implementation built now will likely be obsolete within 90 days when servers provide structured `reasoning_content` fields natively.

**Decision**: Maintain scaffolding as primary thinking mode, revisit native support when ecosystem matures.

**Success Metrics for Revisiting**:
- Community examples of stable implementations
- llama-server documentation for CoT streaming
- Standardized `reasoning_content` field in OpenAI-compatible endpoints
- Reliable streaming in 90%+ of test cases
- Fixed Jinja templates for Qwen reasoning state
- Stable builds without auto-parser regressions
