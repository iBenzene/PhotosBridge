module.exports = {
    extends: ['stylelint-config-standard'],
    ignoreFiles: [
        '**/node_modules/**',
        '**/dist/**',
        '**/coverage/**',
        '**/package-lock.json',
        '**/build/**',
        '**/.mypy_cache/**',
        '**/data/**',
        'apps/apple/**'
    ],
    overrides: [
        {
            customSyntax: 'postcss-html',
            extends: ['stylelint-config-standard-less'],
            files: ['**/*.vue'],
            rules: {
                'selector-pseudo-class-no-unknown': [
                    true,
                    { ignorePseudoClasses: ['deep', 'global', 'slotted'] }
                ]
            }
        },
        { extends: ['stylelint-config-standard-scss'], files: ['**/*.scss'] },
        { extends: ['stylelint-config-standard-less'], files: ['**/*.less'] }
    ],
    plugins: ['stylelint-order', 'stylelint-prettier'],
    rules: {
        'order/properties-alphabetical-order': true,
        'prettier/prettier': true
    }
};
