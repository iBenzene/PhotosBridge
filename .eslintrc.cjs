/**
 * ESLint Configuration
 * Enforces code style consistency across the project
 */

module.exports = {
    root: true,
    env: {
        node: true,
        es2024: true,
    },
    parser: "@typescript-eslint/parser",
    parserOptions: {
        ecmaVersion: "latest",
        sourceType: "module",
    },
    extends: [
        "eslint:recommended",
        "plugin:@typescript-eslint/recommended",
        "plugin:prettier/recommended", // Enables eslint-plugin-prettier and eslint-config-prettier
    ],
    plugins: ["@typescript-eslint", "sort-keys-fix", "jsonc"],
    overrides: [
        {
            // Configuration files - exempt from object key sorting
            files: [".eslintrc.cjs", ".prettierrc.cjs", "*.config.js", "*.config.cjs"],
            rules: {
                "sort-keys-fix/sort-keys-fix": "off",
            },
        },
        {
            // All JSON files - enforce 4-space indentation and sorting
            files: ["**/*.json"],
            extends: ["plugin:jsonc/recommended-with-json", "plugin:prettier/recommended"],
            parser: "jsonc-eslint-parser",
            rules: {
                "jsonc/indent": ["error", 4],
                "jsonc/key-spacing": [
                    "error",
                    {
                        beforeColon: false,
                        afterColon: true,
                    },
                ],
                "jsonc/comma-dangle": ["error", "never"],
            },
        },
        {
            // package.json, package-lock.json - don't sort these files
            files: ["package.json", "package-lock.json"],
            extends: ["plugin:jsonc/recommended-with-json", "plugin:prettier/recommended"],
            parser: "jsonc-eslint-parser",
            rules: {
                "jsonc/indent": ["error", 4],
                "jsonc/sort-keys": "off",
            },
        },
    ],
    rules: {
        // Enforce arrow functions for all function expressions / declarations
        "func-style": ["error", "expression"],
        // ==================== Code Quality ====================
        // Warn about unused variables to prevent dead code
        "no-unused-vars": "off",
        "@typescript-eslint/no-unused-vars": [
            "error",
            {
                vars: "all",
                args: "after-used",
                ignoreRestSiblings: true,
                argsIgnorePattern: "^_",
            },
        ],

        // Allow console statements (server logs)
        "no-console": "off",

        // Disallow var declarations, prefer const/let
        "no-var": "error",
        "prefer-const": [
            "error",
            {
                destructuring: "any",
                ignoreReadBeforeAssign: false,
            },
        ],

        // ==================== Code Style ====================
        // Prefer arrow functions for callbacks
        "prefer-arrow-callback": [
            "error",
            {
                allowNamedFunctions: false,
                allowUnboundThis: true,
            },
        ],

        // Prefer concise arrow function syntax when possible
        "arrow-body-style": ["error", "as-needed"],

        // Prefer object shorthand notation
        "object-shorthand": ["error", "always"],

        // Disallow padding within blocks
        "padded-blocks": ["error", "never"],

        // Enforce sorted object keys (fixable)
        "sort-keys-fix/sort-keys-fix": [
            "error",
            "asc",
            {
                caseSensitive: false,
                natural: true,
            },
        ],

        // Disable JS rules covered by Prettier
        indent: "off",
        quotes: "off",
        semi: "off",
        "comma-dangle": "off",
    },
};
