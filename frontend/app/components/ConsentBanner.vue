<template>
  <div
    v-if="visible"
    data-testid="consent-banner"
    role="dialog"
    aria-labelledby="consent-title"
    aria-describedby="consent-description"
    class="consent-banner"
  >
    <h2 id="consent-title">{{ $t('consent.title') }}</h2>
    <p id="consent-description">{{ $t('consent.description') }}</p>

    <div class="consent-actions">
      <button type="button" :aria-label="$t('consent.accept_aria')" @click="accept">
        {{ $t('consent.accept') }}
      </button>
      <button type="button" :aria-label="$t('consent.decline_aria')" @click="decline">
        {{ $t('consent.decline') }}
      </button>
    </div>
  </div>
</template>

<script setup lang="ts">
/**
 * ConsentBanner — GDPR consent scaffold (C1 structure; full wiring in C7/C8).
 *
 * Emits:
 *   accepted  — user consented to data collection/recording
 *   declined  — user declined; entry to interview must be blocked
 *
 * All text is i18n-keyed; no hardcoded strings (D31).
 * The interview entry route gates on consent accepted before proceeding.
 * In E2E tests the fake-provider fixture acknowledges this event (C7+).
 */
const emit = defineEmits<{
  (e: 'accepted'): void
  (e: 'declined'): void
}>()

const visible = ref(true)

function accept(): void {
  visible.value = false
  emit('accepted')
}

function decline(): void {
  visible.value = false
  emit('declined')
}
</script>
