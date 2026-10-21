You find the questions that a coding agent asks the user, in one unit of one message of the agent.
A unit is one paragraph of the message as plain text on one line. A unit can also be a paragraph that ends with a question or a colon, followed by the list that belongs to it. List markers ("-", "*", "1.", "2)", "a.") are kept. Return JSON only, in this shape:
{"questions": [{"question": "exact text", "kind": "choice|yes_no|open", "options": ["exact text", "exact text"]}]}
A question needs an answer from the user. List the questions in text order; they do not overlap. "question" is a copy of the question's text in the unit, character for character, from its first word to its last character, and it occurs once in the unit.
"kind" is "choice" (the user picks between options that the text names; "options" has them), "yes_no" (the user answers yes or no) or "open" (there is no finite answer, as in "What should the name be?"). Only "choice" has options.
"options" are copies of text inside the question, character for character: no list marker, no trailing full stop, inner punctuation kept, at least 3 characters, no duplicates, each one occurring once in the question. A list item gives one option.
If the unit has no question, return {"questions": []}.
Rules, each with an example:

Several questions in one unit are several questions.
Text: Should I push it now, or wait for CI? Also, do you want the docs updated too?
Answer: {"questions": [{"question": "Should I push it now, or wait for CI?", "kind": "choice", "options": ["push it now", "wait for CI"]}, {"question": "Also, do you want the docs updated too?", "kind": "yes_no", "options": []}]}

A numbered list of questions is several questions, one for each item.
Text: I have two questions. 1. Should I update the docs? 2. What should the name be?
Answer: {"questions": [{"question": "1. Should I update the docs?", "kind": "yes_no", "options": []}, {"question": "2. What should the name be?", "kind": "open", "options": []}]}

A question followed by a list whose items answer it is one question, from the question to the last item. Each item is an option, also when it is a full sentence.
Text: Which should the CLI ship? 1. Only the 1,024 function, with chunking. 2. Both functions, and the CLI selects by text length. 3. Only the 2,048 function.
Answer: {"questions": [{"question": "Which should the CLI ship? 1. Only the 1,024 function, with chunking. 2. Both functions, and the CLI selects by text length. 3. Only the 2,048 function.", "kind": "choice", "options": ["Only the 1,024 function, with chunking", "Both functions, and the CLI selects by text length", "Only the 2,048 function"]}]}

A question can start with a clause.
Text: For the 2,048-token function, which should the CLI ship? - Only the 1,024 function - Both functions
Answer: {"questions": [{"question": "For the 2,048-token function, which should the CLI ship? - Only the 1,024 function - Both functions", "kind": "choice", "options": ["Only the 1,024 function", "Both functions"]}]}

A sentence before the question that only gives context is not part of the question.
Text: I checked the build. Which one do you prefer, the old cache or the new one?
Answer: {"questions": [{"question": "Which one do you prefer, the old cache or the new one?", "kind": "choice", "options": ["the old cache", "the new one"]}]}

A question can come after its options. It starts at the lead-in of the options.
Text: There are two ways: - update the docs - keep the change Which one do you want?
Answer: {"questions": [{"question": "There are two ways: - update the docs - keep the change Which one do you want?", "kind": "choice", "options": ["update the docs", "keep the change"]}]}

Inline options: the option is the noun phrase after "or" or the list word, without the verb that the options share.
Text: Should I update the docs or keep the change?
Answer: {"questions": [{"question": "Should I update the docs or keep the change?", "kind": "choice", "options": ["update the docs", "keep the change"]}]}

A yes/no question has no options. Words like "y/n" or "yes or no" are not options.
Text: Should I run the tests now? Reply y/n.
Answer: {"questions": [{"question": "Should I run the tests now?", "kind": "yes_no", "options": []}]}
