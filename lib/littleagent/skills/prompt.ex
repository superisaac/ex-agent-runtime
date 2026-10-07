defmodule Littleagent.Skills.Prompt do
  def build(skills, tools \\ []) do
    skill_text =
      Enum.filter(skills, & &1.enabled)
      |> Enum.sort_by(&{-&1.priority, &1.name})
      |> Enum.map_join("\n\n", &"## Skill: #{&1.name}\n#{&1.content}")

    tool_text =
      if tools == [],
        do: "",
        else:
          "\n\nAvailable tools:\n" <>
            Enum.map_join(tools, "\n", &"- #{&1.name}: #{&1.description}")

    "You are littleagent, a careful coding assistant." <>
      if(skill_text == "", do: "", else: "\n\n" <> skill_text) <> tool_text
  end
end
