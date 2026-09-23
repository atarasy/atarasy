import SwiftUI
import AtarasyCore
import UIKit

extension Notification.Name {
    static let atarasyAPNSToken = Notification.Name("dev.atarasy.apns-token")
    static let atarasyRefreshHint = Notification.Name("dev.atarasy.refresh-hint")
}
final class AtarasyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { application.registerForRemoteNotifications(); return true }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { NotificationCenter.default.post(name: .atarasyAPNSToken, object: deviceToken) }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: userInfo), MemberRefreshHint.validate(data) else { completionHandler(.noData); return }
        NotificationCenter.default.post(name: .atarasyRefreshHint, object: data); completionHandler(.noData)
    }
}

@main struct AtarasyPrototypeApp: App {
    @UIApplicationDelegateAdaptor(AtarasyAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup {
            #if ATARASY_RELEASE
            MemberProductionRootView()
            #else
            DevelopmentRootView()
            #endif
        }
    }
}

// Everything below is the synthetic design prototype: a fixture-backed inbox with no
// host, credential or payment behind it. `ATARASY_RELEASE` (the Production build
// configuration only) excludes it, so App Review never sees it as the submitted app's
// launch experience; the Production root is `MemberProductionRootView` in
// MemberAccountView.swift.
#if !ATARASY_RELEASE
/// Every non-Production build opens the member's app as Production does. The synthetic design
/// prototype stays reachable with `--prototype` for its UI tests, and the UI-testing
/// configuration adds a fixture-backed household with `--showcase`.
struct DevelopmentRootView: View {
    var body: some View {
        #if ATARASY_UI_TEST_FIXTURES
        if ProcessInfo.processInfo.arguments.contains("--showcase") { MemberShowcaseRootView() } else { standard }
        #else
        standard
        #endif
    }
    @ViewBuilder private var standard: some View {
        if ProcessInfo.processInfo.arguments.contains("--prototype") || ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--member-") }) { InboxView() } else { MemberProductionRootView() }
    }
}
private func merchantName(_ id: String) -> String { id == "merchant-fixture-a" ? "Pantry Market" : "Neighbourhood Goods" }

struct InboxView: View {
    private let fixtures: DemoFixtures = {
        let url=Bundle.main.url(forResource:"fixtures",withExtension:"json")!
        return try! JSONDecoder().decode(DemoFixtures.self,from:Data(contentsOf:url))
    }()
    @State private var selected: String?
    @State private var partial = false
    @State private var memberAccount = false
    @StateObject private var memberHolder = MemberAccountHolder()
    var body: some View {
        NavigationSplitView {
            List(selection:$selected) {
                Section { Text("Design prototype · synthetic data").font(.caption).foregroundStyle(.secondary)
                    Toggle("Simulate incomplete list",isOn:$partial).accessibilityIdentifier("partialToggle")
                    if partial { Text("Some sources could not be checked. This list may be incomplete.").accessibilityIdentifier("partialWarning") }
                }
                ForEach(["physical","digital"],id:\.self) { binding in
                    Section(binding == "physical" ? "Physical" : "Digital") {
                        ForEach(fixtures.visibleOffers(household:fixtures.households[0],binding:binding,unavailablePresenter:partial ? fixtures.merchants[1] : nil)) { offer in
                            NavigationLink(value:offer.id) {
                                VStack(alignment:.leading,spacing:5) { Text(offer.title).font(.headline);Text(merchantName(offer.presenter)).font(.caption).foregroundStyle(.secondary);Text(binding == "physical" ? "Statement ready" : "Proposal available").font(.subheadline) }
                            }.accessibilityIdentifier("offer-"+offer.id)
                        }
                    }
                }
                Section { Button("Member account") { memberAccount = true }.accessibilityIdentifier("memberAccount") }
                Section("Prototype scope") { Text("No payment is performed by the sample inbox. Authenticated Dials require a configured member service; account recovery is not interactive in this build.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Overtures")
        } detail: {
            if let offer=fixtures.offers.first(where:{$0.id == selected}) { OfferView(offer:offer).id(offer.id) }
            else { ContentUnavailableView("Choose a proposal",systemImage:"tray",description:Text("Digital choices and physical statements remain separate.")) }
        }
        .sheet(isPresented: $memberAccount) { MemberAccountSheet(holder: memberHolder) }
        .onReceive(NotificationCenter.default.publisher(for: .atarasyAPNSToken)) { if let token = $0.object as? Data { memberHolder.apnsToken = token } }
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--physical") { selected="physical-a" }; if ProcessInfo.processInfo.arguments.contains("--digital") { selected="digital-a" } }
    }
}
struct OfferView: View {
    let offer: DemoOffer
    @State private var kept=Set<String>()
    @State private var disputed=Set<String>()
    @State private var op=DemoOperation()
    @State private var reviewing=false
    @State private var ceremony=false
    @State private var changed=false
    @State private var missingCarriage=false
    @State private var lostReply=false
    @State private var notice=""
    var physical: Bool { offer.binding == "physical" }
    var storageKey:String { "synthetic-operation-"+offer.id }
    var total:Int64 { offer.amount(kept:kept,disputed:disputed) }
    func canonical() throws -> String {
        if physical { return try Canonical.statement(offer:offer.id,carriage:missingCarriage ? nil : offer.carriage,lines:offer.lines.map { .init(candidate:$0.id,valence:$0.verdict,amount:$0.amount,disputed:["consumed","lost"].contains($0.verdict) && disputed.contains($0.id)) }) }
        return try Canonical.decisions(offer:offer.id,lines:offer.lines.map { .init(candidate:$0.id,valence:kept.contains($0.id) ? "kept" : "returned",keptAs:kept.contains($0.id) ? "self" : nil) })
    }
    func persist() { if let data=try? JSONEncoder().encode(op) { UserDefaults.standard.set(data,forKey:storageKey) } }
    var body: some View {
        Form {
            Section { Text("Simulation only · no charge or credential").font(.caption).foregroundStyle(.secondary) }
            if op.phase == .unknown || op.phase == .confirmed { resultSections }
            else {
                Section(physical ? "Collection statement" : "Digital proposal") {
                    Text(merchantName(offer.presenter)).font(.headline)
                    Text(physical ? "Collection: 13 September 2026 (fixture date). These goods are already with you." : "If you do not choose, this proposal closes without a purchase.")
                }
                ForEach(offer.lines) { line in
                    Section(line.name) {
                        Text("Maker: \(line.maker)")
                        if let giver=line.givenBy { Text("Gift from \(giver). No goods charge to you for this item.") }
                        else { Text("JPY \(line.amount)").monospacedDigit() }
                        if physical {
                            Text(line.verdict == "consumed" ? "Collection reported: Used" : line.verdict == "lost" ? "Collection reported: not in the box. Never charged to you." : "Previously chosen to keep")
                            if line.verdict == "lost" { Toggle("It was in the box",isOn:Binding(get:{disputed.contains(line.id)},set:{if $0 { disputed.insert(line.id) } else { disputed.remove(line.id) }})).accessibilityIdentifier("dispute-"+line.id).disabled(reviewing) }
                            else if line.verdict == "consumed" { Toggle("Dispute this consumed line",isOn:Binding(get:{disputed.contains(line.id)},set:{if $0 { disputed.insert(line.id) } else { disputed.remove(line.id) }})).accessibilityIdentifier("dispute-"+line.id).disabled(reviewing) }
                            else { Text("This line was already your signed choice.").font(.footnote) }
                        } else {
                            Toggle("Choose this item",isOn:Binding(get:{kept.contains(line.id)},set:{if $0 { kept.insert(line.id) } else { kept.remove(line.id) }})).accessibilityIdentifier("choose-"+line.id).disabled(reviewing)
                            Text("Alternative: decline this item. Argument against: you may already have enough.").font(.footnote)
                        }
                        Text("Fixture merchant disclosure: \(merchantName(offer.presenter)) supplies this item. This text is for design testing only.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Review") {
                    Text(missingCarriage ? "Delivery costs have not been recorded." : "Carriage: JPY \(offer.carriage ?? 0)")
                    Text(missingCarriage ? "Amount: awaiting delivery costs" : "Amount authorised: JPY \(total)").font(.headline).accessibilityIdentifier("reviewTotal")
                    if changed { Text("This proposal has changed. Review the current details before signing.").accessibilityIdentifier("changedWarning") }
                    if reviewing {
                        Text(physical ? "Review the statement and any disputed lines above." : "Unselected lines will be explicitly returned in this signed decision.")
                        Button(physical ? "Simulate signing this statement" : "Simulate signing this decision") { do { try op.begin(); ceremony=true } catch { notice="Review the current details again." } }.accessibilityIdentifier("signButton").disabled(changed || missingCarriage)
                        Button("Back to edit") { reviewing=false }
                    } else {
                        Button(physical ? "Review statement" : "Review decision") { do { op.review(try canonical());reviewing=true;notice="" } catch { notice="This statement is not ready to sign." } }.accessibilityIdentifier("reviewButton").disabled(missingCarriage)
                    }
                    if !notice.isEmpty { Text(notice).accessibilityIdentifier("notice") }
                }
                Section("Prototype scenarios") {
                    Toggle("Lose acknowledgement after simulated submission",isOn:$lostReply).accessibilityIdentifier("lostReplyToggle")
                    if physical { Toggle("Missing carriage",isOn:$missingCarriage).accessibilityIdentifier("missingCarriageToggle").onChange(of:missingCarriage) { _,_ in reviewing=false } }
                    Button(changed ? "Load current fixture" : "Simulate changed terms") { changed.toggle(); reviewing=false; op=DemoOperation() }.accessibilityIdentifier("changedTerms")
                }
            }
            Section { Button("Reset this synthetic scenario") { UserDefaults.standard.removeObject(forKey:storageKey);op=DemoOperation();reviewing=false;kept=[];disputed=[];changed=false;missingCarriage=false;notice="" }.accessibilityIdentifier("resetScenario") }
        }
        .navigationTitle(physical ? "Statement" : "Proposal")
        .sheet(isPresented:$ceremony) {
            VStack(spacing:24) {
                Text("Simulated credential ceremony").font(.title2)
                Text("No passkey is used. No request or payment will be sent.").multilineTextAlignment(.center)
                Button("Complete simulation") { do { try op.submit(lostReply:lostReply);persist();ceremony=false } catch { notice="Operation already handled.";ceremony=false } }.buttonStyle(.borderedProminent).accessibilityIdentifier("completeSimulation")
                Button("Cancel signing") { try? op.cancel();ceremony=false;notice="Signing cancelled." }.accessibilityIdentifier("cancelSigning")
            }.padding().presentationDetents([.medium]).interactiveDismissDisabled()
        }
        .onAppear {
            if !ProcessInfo.processInfo.arguments.contains("--fresh"), let data=UserDefaults.standard.data(forKey:storageKey), let restored=try? JSONDecoder().decode(DemoOperation.self,from:data) { op=restored }
            else if ProcessInfo.processInfo.arguments.contains("--fresh") { UserDefaults.standard.removeObject(forKey:storageKey) }
        }
    }
    @ViewBuilder var resultSections: some View {
        Section("Result") {
            if op.phase == .unknown {
                Text("We could not confirm the result. Your request may have arrived.").accessibilityIdentifier("unknownResult")
                Button("Check result") { try? op.reconcile();persist() }.accessibilityIdentifier("checkResult")
            } else { Text("Your \(physical ? "statement" : "decision") was recorded in this simulation.").accessibilityIdentifier("confirmedResult") }
            Text("Payment: \(physical ? "not performed (simulation)" : "external checkout not started")")
            Text("Simulated recorded effects: \(op.simulatedEffects)").accessibilityIdentifier("effectCount")
        }
    }
}
#endif
