# State Management

Strands Agents state is maintained in several forms:

1. **Conversation History:** The sequence of messages between the user and the agent.
2. **Agent State**: Stateful information outside of conversation context, maintained across multiple requests.
3. **Invocation State**: Contextual information maintained within a single invocation.

Understanding how state works in Strands is essential for building agents that can maintain context across multi-turn interactions and workflows.

## Conversation History

[Section titled “Conversation History”](#conversation-history)

Conversation history is the primary form of context in a Strands agent, directly accessible through the agent:

- [Python](#tab-panel-1855)
- [TypeScript](#tab-panel-1856)```
  from strands import Agent

# Create an agentagent = Agent()

# Send a message and get a responseagent("Hello!")

# Access the conversation historyprint(agent.messages) # Shows all messages exchanged so far

````
// Create an agentconst agent = new Agent()
// Send a message and get a responseawait agent.invoke('Hello!')
// Access the conversation historyconsole.log(agent.messages) // Shows all messages exchanged so far
```

The agent messages contains all user and assistant messages, including tool calls and tool results. This is the primary way to inspect what’s happening in your agent’s conversation.

You can initialize an agent with existing messages to continue a conversation or pre-fill your Agent’s context with information:

- [Python](#tab-panel-1859)
- [TypeScript](#tab-panel-1860)```
from strands import Agent
# Create an agent with initial messagesagent = Agent(messages=[    {"role": "user", "content": [{"text": "Hello, my name is Strands!"}]},    {"role": "assistant", "content": [{"text": "Hi there! How can I help you today?"}]}])
# Continue the conversationagent("What's my name?")
````

// Create an agent with initial messagesconst agent = new Agent({ messages: [ { role: 'user', content: [{ text: 'Hello, my name is Strands!' }] }, { role: 'assistant', content: [{ text: 'Hi there! How can I help you today?' }] }, ],})
// Continue the conversationawait agent.invoke("What's my name?")

````

Conversation history is automatically:

- Maintained between calls to the agent
- Passed to the model during each inference
- Used for tool execution context
- Managed to prevent context window overflow

### Direct Tool Calling

[Section titled “Direct Tool Calling”](#direct-tool-calling)

Direct tool calls are (by default) recorded in the conversation history:

- [Python](#tab-panel-1857)
- [TypeScript](#tab-panel-1858)```
from strands import Agentfrom strands_tools import calculator
agent = Agent(tools=[calculator])
# Direct tool call with recording (default behavior)agent.tool.calculator(expression="123 * 456")
# Direct tool call without recordingagent.tool.calculator(expression="765 / 987", record_direct_tool_call=False)
print(agent.messages)
````

In this example we can see that the first `agent.tool.calculator()` call is recorded in the agent’s conversation history.

The second `agent.tool.calculator()` call is **not** recorded in the history because we specified the `record_direct_tool_call=False` argument.```
// Not supported in TypeScript

````

### Conversation Manager

[Section titled “Conversation Manager”](#conversation-manager)

Strands uses a conversation manager to handle conversation history effectively. The default is the [`SlidingWindowConversationManager`](/docs/api/python/strands.agent.conversation_manager.sliding_window_conversation_manager/#SlidingWindowConversationManager), which keeps recent messages and removes older ones when needed:

- [Python](#tab-panel-1861)
- [TypeScript](#tab-panel-1862)```
from strands import Agentfrom strands.agent.conversation_manager import SlidingWindowConversationManager
# Create a conversation manager with custom window size# By default, SlidingWindowConversationManager is used even if not specifiedconversation_manager = SlidingWindowConversationManager(    window_size=10,  # Maximum number of message pairs to keep)
# Use the conversation manager with your agentagent = Agent(conversation_manager=conversation_manager)
````

import { SlidingWindowConversationManager } from '@strands-agents/sdk'// Create a conversation manager with custom window size// By default, SlidingWindowConversationManager is used even if not specifiedconst conversationManager = new SlidingWindowConversationManager({ windowSize: 10,})
const agent = new Agent({ conversationManager,})

````

The sliding window conversation manager:

- Keeps the most recent N message pairs
- Removes the oldest messages when the window size is exceeded
- Handles context window overflow exceptions by reducing context
- Ensures conversations don’t exceed model context limits

See [Conversation Management](/docs/user-guide/concepts/agents/conversation-management/) for more information about conversation managers.

## Agent State

[Section titled “Agent State”](#agent-state)

Agent state (also called app state) provides key-value storage for stateful information that exists outside of the conversation context. Unlike conversation history, agent state is not passed to the model during inference but can be accessed and modified by tools and application logic.

### Basic Usage

[Section titled “Basic Usage”](#basic-usage)

- [Python](#tab-panel-1863)
- [TypeScript](#tab-panel-1864)```
from strands import Agent
# Create an agent with initial stateagent = Agent(state={"user_preferences": {"theme": "dark"}, "session_count": 0})

# Access state valuestheme = agent.state.get("user_preferences")print(theme)  # {"theme": "dark"}
# Set new state valuesagent.state.set("last_action", "login")agent.state.set("session_count", 1)
# Get entire stateall_state = agent.state.get()print(all_state)  # All state data as a dictionary
# Delete state valuesagent.state.delete("last_action")
````

// Create an agent with initial stateconst agent = new Agent({ appState: { user_preferences: { theme: 'dark' }, session_count: 0 },})
// Access state valuesconst theme = agent.appState.get('user_preferences')console.log(theme) // { theme: 'dark' }
// Set new state valuesagent.appState.set('last_action', 'login')agent.appState.set('session_count', 1)
// Get state values individuallyconsole.log(agent.appState.get('user_preferences'))console.log(agent.appState.get('session_count'))
// Delete state valuesagent.appState.delete('last_action')

````

### State Validation and Safety

[Section titled “State Validation and Safety”](#state-validation-and-safety)

Agent state enforces JSON serialization validation to ensure data can be persisted and restored:

- [Python](#tab-panel-1865)
- [TypeScript](#tab-panel-1866)```
from strands import Agent
agent = Agent()
# Valid JSON-serializable valuesagent.state.set("string_value", "hello")agent.state.set("number_value", 42)agent.state.set("boolean_value", True)agent.state.set("list_value", [1, 2, 3])agent.state.set("dict_value", {"nested": "data"})agent.state.set("null_value", None)
# Invalid values will raise ValueErrortry:    agent.state.set("function", lambda x: x)  # Not JSON serializableexcept ValueError as e:    print(f"Error: {e}")
````

const agent = new Agent()
// Valid JSON-serializable valuesagent.appState.set('string_value', 'hello')agent.appState.set('number_value', 42)agent.appState.set('boolean_value', true)agent.appState.set('list_value', [1, 2, 3])agent.appState.set('dict_value', { nested: 'data' })agent.appState.set('null_value', null)
// Invalid values will raise an errortry { agent.appState.set('function', () => 'test') // Not JSON serializable} catch (error) { console.log(`Error: ${error}`)}

````

### Using State in Tools

[Section titled “Using State in Tools”](#using-state-in-tools)

Note

To use `ToolContext` in your tool function, the parameter must be named `tool_context`. See [ToolContext documentation](/docs/user-guide/concepts/tools/custom-tools/#toolcontext) for more information.

Agent state is particularly useful for maintaining information across tool executions:

- [Python](#tab-panel-1867)
- [TypeScript](#tab-panel-1868)```
from strands import Agent, tool, ToolContext
@tool(context=True)def track_user_action(action: str, tool_context: ToolContext):    """Track user actions in agent state.
    Args:        action: The action to track    """    # Get current action count    action_count = tool_context.agent.state.get("action_count") or 0
    # Update state    tool_context.agent.state.set("action_count", action_count + 1)    tool_context.agent.state.set("last_action", action)
    return f"Action '{action}' recorded. Total actions: {action_count + 1}"
@tool(context=True)def get_user_stats(tool_context: ToolContext):    """Get user statistics from agent state."""    action_count = tool_context.agent.state.get("action_count") or 0    last_action = tool_context.agent.state.get("last_action") or "none"
    return f"Actions performed: {action_count}, Last action: {last_action}"
# Create agent with toolsagent = Agent(tools=[track_user_action, get_user_stats])
# Use tools that modify and read stateagent("Track that I logged in")agent("Track that I viewed my profile")print(f"Actions taken: {agent.state.get('action_count')}")print(f"Last action: {agent.state.get('last_action')}")
````

const trackUserActionTool = tool({ name: 'track_user_action', description: 'Track user actions in agent state', inputSchema: z.object({ action: z.string().describe('The action to track'), }), callback: (input, context?: ToolContext) => { if (!context) { throw new Error('Context is required') }
// Get current action count const actionCount = (context.agent.appState.get('action_count') as number) || 0
// Update state context.agent.appState.set('action_count', actionCount + 1) context.agent.appState.set('last_action', input.action)
return `Action '${input.action}' recorded. Total actions: ${actionCount + 1}` },})
const getUserStatsTool = tool({ name: 'get_user_stats', description: 'Get user statistics from agent state', inputSchema: z.object({}), callback: (input, context?: ToolContext) => { if (!context) { throw new Error('Context is required') }
const actionCount = (context.agent.appState.get('action_count') as number) || 0 const lastAction = (context.agent.appState.get('last_action') as string) || 'none'
return `Actions performed: ${actionCount}, Last action: ${lastAction}` },})
// Create agent with toolsconst agent = new Agent({ tools: [trackUserActionTool, getUserStatsTool],})
// Use tools that modify and read stateawait agent.invoke('Track that I logged in')await agent.invoke('Track that I viewed my profile')console.log(`Actions taken: ${agent.appState.get('action_count')}`)console.log(`Last action: ${agent.appState.get('last_action')}`)

````

## Invocation State

[Section titled “Invocation State”](#invocation-state)

Each agent interaction maintains an invocation state dictionary that persists throughout the event loop cycles and is **not** included in the agent’s context:

- [Python](#tab-panel-1869)
- [TypeScript](#tab-panel-1870)```
from strands import Agent
def custom_callback_handler(**kwargs):    # Access request state    if "request_state" in kwargs:        state = kwargs["request_state"]        # Use or modify state as needed        if "counter" not in state:            state["counter"] = 0        state["counter"] += 1        print(f"Callback handler event count: {state['counter']}")
agent = Agent(callback_handler=custom_callback_handler)
result = agent("Hi there!")
print(result.state)
````

const agent = new Agent()
// Pass per-invocation state when invokingconst result = await agent.invoke('Hi there!', { invocationState: { requestId: 'r-42', userId: 'u-1' },})
// Hooks and tools can read and mutate invocationState during// the invocation. The same object is returned on the result.console.log(result.invocationState)// { requestId: 'r-42', userId: 'u-1', ... }

```

Invocation state (`invocation_state``invocationState`):

- Is initialized at the beginning of each agent invocation (defaults to `{}` when omitted)
- Persists through recursive event loop cycles within a single invocation
- Is shared by reference across all hook events and tools
- Mutations by hooks or tools are visible to subsequent hooks, tools, and the final result
- Is returned on the `AgentResult` (Python: `result.state`, TypeScript: `result.invocationState`)
- Is **not** included in the agent’s model context

## Persisting State Across Sessions

[Section titled “Persisting State Across Sessions”](#persisting-state-across-sessions)

For automatic persistence of agent state and conversation history across application restarts, see [Session Management](/docs/user-guide/concepts/agents/session-management/). For manual, point-in-time capture and restore of agent state, see [Snapshots](/docs/user-guide/concepts/agents/snapshots/).
```
