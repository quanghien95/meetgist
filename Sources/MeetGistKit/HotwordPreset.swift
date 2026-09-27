// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A named, ready-made list of hotwords/context keywords the user can drop
/// into the offline transcription vocabulary field in one click.
public struct HotwordPreset: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let keywords: String

    public init(id: String, name: String, keywords: String) {
        self.id = id
        self.name = name
        self.keywords = keywords
    }
}

public enum HotwordPresets {
    public static let itEcommerce = HotwordPreset(
        id: "it-ecommerce",
        name: "IT / E-commerce",
        keywords: "Shopify, Klaviyo, Nosto, Hyvä, CloudFront, DynamoDB, GRIT, RIMAN, metafield, metaobject"
    )
    public static let genericTech = HotwordPreset(
        id: "generic-tech",
        name: "Generic Tech / Software",
        keywords: "API, SDK, webhook, GraphQL, CI/CD, Kubernetes, microservices, OAuth, REST, JSON, backend, frontend, deployment, repository, staging, production"
    )
    public static let meetingBusiness = HotwordPreset(
        id: "meeting-business",
        name: "Meeting / Business",
        keywords: "stakeholder, roadmap, sprint, backlog, KPI, ROI, deadline, milestone, deliverable, onboarding, retrospective"
    )

    public static let all: [HotwordPreset] = [itEcommerce, genericTech, meetingBusiness]

    /// Seeded into the vocabulary field on first launch; the same content as
    /// the `itEcommerce` preset, since it's the closest match to this app's
    /// default audience.
    public static let defaultKeywords = itEcommerce.keywords
}
