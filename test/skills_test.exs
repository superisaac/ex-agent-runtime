defmodule Ear.SkillsTest do
  use ExUnit.Case, async: true

  test "skill loader rejects a symlink escaping its root" do
    root =
      Path.join(System.tmp_dir!(), "ear-skills-#{System.unique_integer([:positive])}")

    outside =
      Path.join(System.tmp_dir!(), "ear-skills-out-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "SKILL.md"), "---\nname: secret\ndescription: secret\n---\n")
    link = Path.join(root, "linked")
    File.ln_s!(outside, link)

    assert {:error, {:path_outside_root, _}} =
             Ear.Skills.Loader.load_report(Path.join(link, "SKILL.md"), root)

    File.rm_rf!(root)
    File.rm_rf!(outside)
  end
end
