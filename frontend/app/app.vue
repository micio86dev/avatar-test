<template>
  <div>
    <NuxtRouteAnnouncer />
    <NuxtPage />
  </div>
</template>

<script setup lang="ts">
const runtimeConfig = useRuntimeConfig()
const appEnv = runtimeConfig.public.appEnv as string

// Inject noindex on local and staging environments
if (appEnv !== 'production') {
  useHead({
    meta: [{ name: 'robots', content: 'noindex, nofollow' }],
  })
}
</script>
