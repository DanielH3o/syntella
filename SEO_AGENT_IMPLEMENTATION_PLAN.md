# SEO Agent Implementation Plan

This file turns the Wonderful Payments / Asima client SEO brief into an implementation plan for Syntella.

The goal is not a generic "SEO bot". The goal is a governed, site-aware authority and optimisation agent that:

- monitors search and industry signals continuously
- plans and drafts content across two brands
- improves existing content based on performance
- produces durable reports and operational tasks
- publishes only through controlled approval paths

This plan explicitly excludes paid editorial placements and paid acquisition automation.

## Scope

The agent operates across two properties:

- `Asima`
  - infrastructure and fintech authority site
  - topics: APIs, architecture, enterprise payments, open banking infrastructure, regulation
- `Wonderful Payments`
  - merchant-facing payments platform
  - topics: pay by bank, payment acceptance, payment costs, ecommerce, SME education

The agent should continuously pursue:

- topical authority growth
- AI citation visibility
- demand-led search capture
- internal authority clustering
- brand citation expansion through commentary and data-backed insight

## Recommended Architecture

Use one primary skill plus a small set of focused tools.

### Core skill

`seo-authority-operator`

This skill should teach the agent:

- the difference between `Asima` and `Wonderful`
- the three content streams
- how to choose the right site for a topic
- how to choose between:
  - new authority article
  - commentary / reaction post
  - ecosystem amplification content
  - refresh / optimisation of an existing page
- quality rules:
  - factual accuracy
  - credible citations
  - non-promotional tone
  - technical clarity
  - regulatory awareness
- clustering rules:
  - every article should strengthen a cluster
  - every article should add internal links
  - every content decision should support a pillar topic
- governance rules:
  - drafts may be created automatically
  - final publishing should remain approval-gated
  - paid placements are out of scope

This skill is the decision layer. It should not hardcode API behavior. API access belongs in tools.

### Supporting tools

#### Existing tools to reuse

- `tasks`
  - use for editorial queue, refresh tasks, follow-up actions, approval tasks
- `reports`
  - use for daily summaries, weekly performance reports, opportunity reviews, content output logs

#### New tools to build

- `search-console`
- `analytics`
- `ghost`
- `signals`

Optional later:

- `social-publish`
- `seo-clusters`

## Tool Design

Keep tools narrow and typed. Do not build a single giant `seo` tool.

### 1. `search-console` tool

Purpose:

- inspect search opportunities
- inspect underperforming or rising pages
- request indexing after content updates

Actions:

- `query_opportunities`
  - inputs:
    - `site`
    - `days`
    - `min_impressions`
    - `position_min`
    - `position_max`
  - output:
    - queries with impressions, clicks, ctr, average position

- `page_opportunities`
  - inputs:
    - `site`
    - `days`
    - `position_min`
    - `position_max`
  - output:
    - pages with opportunity signals and supporting queries

- `declining_pages`
  - inputs:
    - `site`
    - `compare_days`
  - output:
    - pages losing impressions/clicks or average position

- `index_issues`
  - inputs:
    - `site`
  - output:
    - known indexing / coverage issues

- `request_indexing`
  - inputs:
    - `site`
    - `url`
  - output:
    - accepted / failed with message

### 2. `analytics` tool

Purpose:

- understand real post-publication performance
- find high-engagement and low-engagement pages
- tie SEO work to meaningful outcomes

Actions:

- `landing_pages`
  - inputs:
    - `site`
    - `days`
  - output:
    - top landing pages with sessions, engagement, conversions

- `organic_trends`
  - inputs:
    - `site`
    - `days`
  - output:
    - organic traffic trend summary

- `content_engagement`
  - inputs:
    - `site`
    - `url` optional
    - `days`
  - output:
    - engagement time, bounce/exit proxies, conversion context

- `conversion_summary`
  - inputs:
    - `site`
    - `days`
  - output:
    - SEO-adjacent conversion metrics

### 3. `ghost` tool

Purpose:

- create and update drafts in the correct brand CMS
- enrich content with metadata and internal linking
- optionally publish only through approval rules

Actions:

- `list_posts`
  - inputs:
    - `site`
    - `status` optional

- `get_post`
  - inputs:
    - `site`
    - `post_id`

- `create_draft`
  - inputs:
    - `site`
    - `title`
    - `html` or `lexical`
    - `excerpt`
    - `slug`
    - `meta_title`
    - `meta_description`
    - `tags`
    - `canonical_url` optional
    - `internal_links` optional
  - output:
    - draft id, preview url

- `update_post`
  - inputs:
    - `site`
    - `post_id`
    - same editable fields as above

- `submit_for_approval`
  - inputs:
    - `site`
    - `post_id`
    - `notes`
  - output:
    - approval status marker or task linkage

Do not enable autonomous final publish in v1.

### 4. `signals` tool

Purpose:

- aggregate external trend monitoring without forcing the model to manually scrape every cycle

Actions:

- `regulatory_updates`
  - inputs:
    - `days`
    - `keywords` optional
  - output:
    - relevant FCA / Open Banking / gov updates

- `fintech_news`
  - inputs:
    - `days`
    - `keywords` optional
  - output:
    - relevant sector news with summaries and URLs

- `competitor_activity`
  - inputs:
    - `days`
    - `competitors`
  - output:
    - new competitor content and observed themes

- `topic_opportunities`
  - inputs:
    - `site`
    - `days`
  - output:
    - prioritised commentary / authority opportunities

The tool should normalize and deduplicate feeds. The skill should decide what matters.

## Skill Design

Create a seeded skill:

- `scripts/templates/workspace/skills/seo-authority-operator/SKILL.md`

Recommended structure:

1. Mission
2. Site selection rules
3. Content stream rules
4. Daily operating loop
5. Drafting rules
6. Refresh rules
7. Reporting rules
8. Governance and approval rules
9. Tool usage rules

The skill should explicitly tell the agent:

- always decide site first
- always decide whether the best action is:
  - report
  - task
  - content refresh
  - new draft
- use `tasks` for queue/state
- use `reports` for durable reasoning and daily summaries
- use `ghost` only for draft creation/update unless explicitly approved to publish
- avoid generic SEO output; every piece must map to authority, demand, or commentary strategy

## Recommended Routine Set

Routines should drive the operating cadence.

### 1. `Daily SEO Review`

Agent:

- SEO agent

Purpose:

- inspect current month traffic/search movement
- identify opportunities and declines
- produce report
- create follow-up tasks

Uses:

- `search-console`
- `analytics`
- `reports`
- `tasks`

Output mode:

- `report + task if needed`

### 2. `Daily Industry Monitor`

Purpose:

- watch regulation, fintech news, and competitors
- identify commentary opportunities

Uses:

- `signals`
- `reports`
- `tasks`

Output mode:

- `report + task if needed`

### 3. `Weekly Editorial Planner`

Purpose:

- maintain the editorial queue across:
  - long-form authority pieces
  - commentary posts
  - refresh candidates
  - amplification pieces

Uses:

- `search-console`
- `analytics`
- `signals`
- `tasks`
- `reports`

Output mode:

- `report + tasks`

### 4. `Draft Production Run`

Purpose:

- turn high-priority queued items into Ghost drafts

Uses:

- `ghost`
- `tasks`
- `reports`

Output mode:

- `report + task if needed`

### 5. `Performance Refresh Review`

Purpose:

- review content published or updated 7–30 days ago
- recommend headline, structure, internal-link, or expansion changes

Uses:

- `search-console`
- `analytics`
- `tasks`
- `reports`

Output mode:

- `report + tasks`

### 6. `Cluster Health Review`

Purpose:

- ensure pillar/supporting topic coverage is becoming coherent

Uses:

- `ghost`
- `search-console`
- `reports`

Output mode:

- `report only` initially

## Operational Rules

### Site routing

Route content to `Asima` when the topic is mainly:

- infrastructure
- APIs
- regulation
- architecture
- enterprise technical strategy

Route content to `Wonderful` when the topic is mainly:

- merchant adoption
- payment cost
- ecommerce payment decisions
- SME education
- pay-by-bank commercial intent

### Content streams

The agent should classify every content action into one of:

- `authority_article`
- `commentary_post`
- `refresh_update`
- `amplification_asset`

The task queue should store this class explicitly.

### Required outputs for each content cycle

Every meaningful cycle should end in one or more of:

- a report
- one or more tasks
- a Ghost draft
- an approval task for a draft

Avoid hidden work with no durable trace.

## Data Model Additions

### Tasks

Recommended task metadata additions:

- `site`
  - `asima` or `wonderful`
- `workstream`
  - `authority_article`
  - `commentary_post`
  - `refresh_update`
  - `amplification_asset`
- `source_signal`
  - `search_console`
  - `analytics`
  - `regulatory`
  - `news`
  - `competitor`
  - `manual`
- `target_url` optional
- `target_query` optional
- `ghost_post_id` optional

### Reports

Recommended report metadata additions:

- `site`
- `report_kind`
  - `daily_review`
  - `industry_monitor`
  - `editorial_plan`
  - `performance_refresh`
  - `cluster_review`
- `primary_recommendations`

These can start as JSON metadata or simple structured body sections.

## Build Order

Build this in stages.

### Phase 1: decision layer

1. Create `seo-authority-operator` skill
2. Define task/report conventions for SEO work
3. Add recommended SEO routine templates to the plan and UI copy

This gives the agent a coherent operating model before adding integrations.

### Phase 2: read-only intelligence

4. Build `search-console` tool
5. Build `analytics` tool
6. Build `signals` tool

At the end of Phase 2, the agent should be able to:

- discover opportunities
- monitor performance
- generate reports
- create queue tasks

without publishing anything.

### Phase 3: publishing workflow

7. Build `ghost` tool with:
   - `list_posts`
   - `get_post`
   - `create_draft`
   - `update_post`
   - `submit_for_approval`
8. Add approval-task generation around draft creation

At the end of Phase 3, the system becomes operational.

### Phase 4: optimisation maturity

9. Add richer cluster analysis
10. Add structured internal-link recommendations
11. Add report templates for weekly/monthly review
12. Add social output support if still desired

## Immediate Repo Work

The next concrete changes in this repo should be:

1. Create the `seo-authority-operator` skill scaffold under workspace templates.
2. Add a first-class `site` and `workstream` concept to SEO-related task creation.
3. Add routine templates for:
   - Daily SEO Review
   - Daily Industry Monitor
   - Weekly Editorial Planner
   - Draft Production Run
   - Performance Refresh Review
4. Only after that, start building the real integrations:
   - Search Console
   - Analytics
   - Ghost
   - Signals

## Non-Goals For V1

- autonomous final publishing without approval
- automated link buying or paid placement operations
- outreach automation
- social account posting without explicit approval
- backlink spam or scaled low-quality citation tactics

## Summary

Best design:

- one strong SEO strategy skill for judgment
- small deterministic tools for data and CMS actions
- routines to drive the daily operating loop
- `tasks` and `reports` as the operational memory layer
- approval-gated publishing

That gives the client a credible autonomous SEO system without turning it into an uncontrolled content bot.
