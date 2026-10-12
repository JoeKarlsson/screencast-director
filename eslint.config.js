// ESLint for the TypeScript CLI, planner and Remotion composition. Run with `npm run lint`.
import js from "@eslint/js";
import reactHooks from "eslint-plugin-react-hooks";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["node_modules/", "projects/", "dist/", "out/", "macos/", ".claude/"] },
  js.configs.recommended,
  tseslint.configs.recommended,
  {
    files: ["src/**/*.tsx"],
    plugins: { "react-hooks": reactHooks },
    rules: reactHooks.configs.recommended.rules,
  },
  {
    rules: {
      // `_`-prefixed names mark intentionally unused parameters and destructured fields.
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
    },
  },
);
