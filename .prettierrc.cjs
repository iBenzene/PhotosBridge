/**
 * Prettier Configuration
 * Formats code consistently across the project
 * Works in conjunction with ESLint via eslint-plugin-prettier
 */

module.exports = {
    // ==================== Basic Formatting ====================
    // Use 4 spaces for indentation (default for code files)
    tabWidth: 4,
    useTabs: false,

    // Line endings
    endOfLine: "lf",

    // ==================== String & Quotes ====================
    // Use double quotes for JS/TS
    singleQuote: false,
    quoteProps: "as-needed",

    // ==================== Semicolons & Commas ====================
    semi: true,
    trailingComma: "es5", // Trailing commas where valid in ES5 (objects, arrays, etc.)

    // ==================== Line Length ====================
    printWidth: 120,

    // ==================== Spacing ====================
    bracketSpacing: true,
    bracketSameLine: false,
    arrowParens: "avoid", // Omit parens when possible (a => a)

    // ==================== File-specific Overrides ====================
    overrides: [
        {
            // All JSON files - use 4 spaces
            files: "*.json",
            options: {
                tabWidth: 4,
                trailingComma: "none",
            },
        },
        {
            // Backend JavaScript & TypeScript files - use double quotes and 4 spaces
            files: ["apps/**/*.ts", "apps/**/*.js", "*.config.js", "*.config.cjs", ".*.cjs"],
            options: {
                tabWidth: 4,
                singleQuote: false,
            },
        },
        {
            // Markdown files
            files: ["*.md"],
            options: {
                tabWidth: 2,
                proseWrap: "preserve",
            },
        },
        {
            // YAML files
            files: ["*.{yml,yaml}"],
            options: {
                tabWidth: 4,
            },
        },
    ],
};
