<template>
  <div>
    <NuxtRouteAnnouncer />
    <NuxtPage />
  </div>
</template>

<script setup lang="ts">
// D30 — backoffice ALWAYS injects noindex in every environment.
// The admin panel must never be indexed by search engines.
useHead({
  meta: [{ name: 'robots', content: 'noindex, nofollow' }],
})
</script>
