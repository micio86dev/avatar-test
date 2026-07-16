<template>
  <div data-testid="unsupported-gate" role="main" aria-labelledby="unsupported-title">
    <h1 id="unsupported-title">{{ $t('unsupported.title') }}</h1>
    <p>{{ $t('unsupported.message') }}</p>
  </div>
</template>

<script setup lang="ts">
definePageMeta({
  name: 'unsupported',
})

useHead({
  meta: [{ name: 'robots', content: 'noindex, nofollow' }],
})
</script>
