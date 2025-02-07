//
//  ActivitiesService.swift
//  AlphaWallet
//
//  Created by Vladyslav Shepitko on 17.05.2021.
//

import Foundation
import CoreFoundation
import PromiseKit
import Combine

protocol ActivitiesServiceType: class {
    var sessions: ServerDictionary<WalletSession> { get }
    var subscribableViewModel: Subscribable<ActivitiesViewModel> { get }
    var subscribableUpdatedActivity: Subscribable<Activity> { get }

    func stop()
    func reinject(activity: Activity)
    func copy(activitiesFilterStrategy: ActivitiesFilterStrategy, transactionsFilterStrategy: TransactionsFilterStrategy) -> ActivitiesServiceType
}

// swiftlint:disable type_body_length
class ActivitiesService: NSObject, ActivitiesServiceType {
    private let config: Config
    let sessions: ServerDictionary<WalletSession>
    private let tokensDataStore: TokensDataStore

    private let assetDefinitionStore: AssetDefinitionStore
    private let eventsActivityDataStore: EventsActivityDataStoreProtocol
    private let eventsDataStore: NonActivityEventsDataStore
    //Dictionary for lookup. Using `.firstIndex` too many times is too slow (60s for 10k events)
    private var activitiesIndexLookup: [Int: (index: Int, activity: Activity)] = .init()
    private var activities: [Activity] = .init()

    private var tokensAndTokenHolders: [AlphaWallet.Address: (tokenObject: Activity.AssignedToken, tokenHolders: [TokenHolder])] = .init()
    private var rateLimitedViewControllerReloader: RateLimiter?
    private var hasLoadedActivitiesTheFirstTime = false
    private var fetchTransactionsCancelable: AnyCancellable?

    let subscribableUpdatedActivity: Subscribable<Activity> = .init(nil)
    let subscribableViewModel: Subscribable<ActivitiesViewModel> = .init(.init(activities: []))

    private var wallet: Wallet {
        sessions.anyValue.account
    }

    private let queue: DispatchQueue

    private let activitiesFilterStrategy: ActivitiesFilterStrategy
    private var filteredTransactionsSubscriptionKey: Subscribable<[TransactionInstance]>.SubscribableKey!
    private let transactionDataStore: TransactionDataStore
    private let transactionsFilterStrategy: TransactionsFilterStrategy

    private typealias ContractsAndCards = [(tokenContract: AlphaWallet.Address, server: RPCServer, card: TokenScriptCard, interpolatedFilter: String)]
    private typealias ActivityTokenObjectTokenHolder = (activity: Activity, tokenObject: Activity.AssignedToken, tokenHolder: TokenHolder)
    private typealias TokenObjectsAndXMLHandlers = [(contract: AlphaWallet.Address, server: RPCServer, xmlHandler: XMLHandler)]

    private var contractsAndCardsPromise: Promise<ActivitiesService.ContractsAndCards>?
    //Cache tokens lookup for performance
    private var tokensCache: ThreadSafeDictionary<AlphaWallet.Address, Activity.AssignedToken> = .init()
    private let activitiesThreadSafeQueue = DispatchQueue(label: "ActivitiesSynchronizedAccessQueue", qos: .background)
    private var cancelable = Set<AnyCancellable>()

    init(
        config: Config,
        sessions: ServerDictionary<WalletSession>,
        assetDefinitionStore: AssetDefinitionStore,
        eventsActivityDataStore: EventsActivityDataStoreProtocol,
        eventsDataStore: NonActivityEventsDataStore,
        transactionDataStore: TransactionDataStore,
        activitiesFilterStrategy: ActivitiesFilterStrategy = .none,
        transactionsFilterStrategy: TransactionsFilterStrategy = .all,
        queue: DispatchQueue,
        tokensDataStore: TokensDataStore
    ) {
        self.queue = queue
        self.config = config
        self.sessions = sessions
        self.assetDefinitionStore = assetDefinitionStore
        self.eventsDataStore = eventsDataStore
        self.eventsActivityDataStore = eventsActivityDataStore
        self.activitiesFilterStrategy = activitiesFilterStrategy
        self.transactionDataStore = transactionDataStore
        self.transactionsFilterStrategy = transactionsFilterStrategy
        self.tokensDataStore = tokensDataStore
        super.init()

        transactionDataStore
            .transactionsChangesetPublisher(forFilter: transactionsFilterStrategy, servers: config.enabledServers)
            .receive(on: queue)
            .sink { [weak self] _ in
                self?.reloadImpl(reloadImmediately: true)
            }.store(in: &cancelable)

        eventsActivityDataStore
            .recentEventsPublisher
            .receive(on: queue)
            .sink { [weak self]  _ in
                self?.reloadImpl(reloadImmediately: true)
            }.store(in: &cancelable)
    }

    func copy(activitiesFilterStrategy: ActivitiesFilterStrategy, transactionsFilterStrategy: TransactionsFilterStrategy) -> ActivitiesServiceType {
        return ActivitiesService(config: config, sessions: sessions, assetDefinitionStore: assetDefinitionStore, eventsActivityDataStore: eventsActivityDataStore, eventsDataStore: eventsDataStore, transactionDataStore: transactionDataStore, activitiesFilterStrategy: activitiesFilterStrategy, transactionsFilterStrategy: transactionsFilterStrategy, queue: queue, tokensDataStore: tokensDataStore)
    }

    func stop() {
        //TODO seems not good to stop here because others call stop too
        for each in sessions.values {
            each.stop()
        }
    }

    //NOTE: it seems like most of operation in reloadImpl(reloadImmediately could be cached
    private func reloadImpl(reloadImmediately: Bool) {
        if let promise = contractsAndCardsPromise, promise.isPending {
            return
        }
        let enabledServers = self.config.enabledServers
        let promise = firstly {
            Promise<[TokenObject]> { seal in
                DispatchQueue.main.async {
                    switch self.transactionsFilterStrategy {
                    case .all:
                        let tokenObjects = self.tokensDataStore.enabledTokenObjects(forServers: self.config.enabledServers)
                        seal.fulfill(tokenObjects)
                    case .filter(_, let tokenObject):
                        seal.fulfill([tokenObject])
                    case .predicate:
                        //NOTE: not supported here
                        seal.fulfill([])
                    }
                }
            }
        }.map(on: .main, { tokensInDatabase -> TokenObjectsAndXMLHandlers in
            return tokensInDatabase.compactMap { each in
                let eachContract = each.contractAddress
                let eachServer = each.server
                let xmlHandler = XMLHandler(token: each, assetDefinitionStore: self.assetDefinitionStore)
                guard xmlHandler.hasAssetDefinition else { return nil }
                guard xmlHandler.server?.matches(server: eachServer) ?? false else { return nil }

                return (contract: eachContract, server: eachServer, xmlHandler: xmlHandler)
            }
        }).map(on: queue, { contractServerXmlHandlers -> ContractsAndCards in
            let contractsAndCardsOptional: [ContractsAndCards] = contractServerXmlHandlers.compactMap { eachContract, _, xmlHandler in
                var contractAndCard: ContractsAndCards = .init()
                for card in xmlHandler.activityCards {
                    let (filterName, filterValue) = card.eventOrigin.eventFilter
                    let interpolatedFilter: String
                    if let implicitAttribute = EventSourceCoordinator.functional.convertToImplicitAttribute(string: filterValue) {
                        switch implicitAttribute {
                        case .tokenId:
                            continue
                        case .ownerAddress:
                            interpolatedFilter = "\(filterName)=\(self.wallet.address.eip55String)"
                        case .label, .contractAddress, .symbol:
                            //TODO support more?
                            continue
                        }
                    } else {
                        //TODO support things like "$prefix-{tokenId}"
                        continue
                    }

                    guard let server = xmlHandler.server else { continue }
                    switch server {
                    case .any:
                        for each in enabledServers {
                            contractAndCard.append((tokenContract: eachContract, server: each, card: card, interpolatedFilter: interpolatedFilter))
                        }
                    case .server(let server):
                        contractAndCard.append((tokenContract: eachContract, server: server, card: card, interpolatedFilter: interpolatedFilter))
                    }
                }
                return contractAndCard
            }
            return contractsAndCardsOptional.flatMap { $0 }
        })

        contractsAndCardsPromise = promise

        promise.done(on: .main, { [weak self] contractsAndCards in
            guard let strongSelf = self else { return }

            strongSelf.fetchAndRefreshActivities(contractsAndCards: contractsAndCards, reloadImmediately: reloadImmediately)
        }).cauterize()
    }

    private func fetchAndRefreshActivities(contractsAndCards: ContractsAndCards, reloadImmediately: Bool) {
        Promise<[ActivityTokenObjectTokenHolder]> { seal in
            var activitiesAndTokens: [ActivityTokenObjectTokenHolder] = .init()
            //NOTE: here is a lot of calculations, `contractsAndCards` could reach up of 1000 items, as well as recentEvents could reach 1000.Simply it call inner function 1 000 000 times
            for (eachContract, eachServer, card, interpolatedFilter) in contractsAndCards {
                let activities = getActivities(forTokenContract: eachContract, server: eachServer, card: card, interpolatedFilter: interpolatedFilter)
                activitiesAndTokens.append(contentsOf: activities)
            }
            seal.fulfill(activitiesAndTokens)
        }.done(on: queue, { [weak self] activitiesAndTokens in
            guard let strongSelf = self else { return }

            let activitiesAndTokens = Self.filter(activities: activitiesAndTokens, strategy: strongSelf.activitiesFilterStrategy)

            strongSelf.activities = activitiesAndTokens.compactMap { $0.activity }
            strongSelf.activities.sort { $0.blockNumber > $1.blockNumber }
            strongSelf.updateActivitiesIndexLookup()

            strongSelf.reloadViewController(reloadImmediately: reloadImmediately)

            for (activity, tokenObject, tokenHolder) in activitiesAndTokens {
                strongSelf.refreshActivity(tokenObject: tokenObject, tokenHolder: tokenHolder, activity: activity)
            }
        }).cauterize()
    }

    private static func filter(activities filteredActivitiesForThisCard: [ActivitiesService.ActivityTokenObjectTokenHolder], strategy: ActivitiesFilterStrategy) -> [ActivitiesService.ActivityTokenObjectTokenHolder] {
        switch strategy {
        case .none:
            return filteredActivitiesForThisCard
        case .contract(let contract), .operationTypes(_, let contract):
            return filteredActivitiesForThisCard.filter { mapped -> Bool in
                return mapped.tokenObject.contractAddress.sameContract(as: contract)
            }
        case .nativeCryptocurrency(let primaryKey):
            return filteredActivitiesForThisCard.filter { mapped -> Bool in
                return mapped.tokenObject.primaryKey == primaryKey
            }
        }
    }

    private func getActivities(forTokenContract contract: AlphaWallet.Address, server: RPCServer, card: TokenScriptCard, interpolatedFilter: String) -> [ActivityTokenObjectTokenHolder] {
        //NOTE: eventsActivityDataStore. getRecentEvents() returns only 100 events, that could cause error with creating activities (missing events)
        //replace with fetching only filtered event instances,
        let events = eventsActivityDataStore.getRecentEventsSortedByBlockNumber(forContract: card.eventOrigin.contract, server: server, eventName: card.eventOrigin.eventName, interpolatedFilter: interpolatedFilter)

        let activitiesForThisCard: [ActivityTokenObjectTokenHolder] = events.compactMap { eachEvent in
            let token: Activity.AssignedToken
            if let t = tokensCache[contract] {
                token = t
            } else {
                guard let t = tokensDataStore.token(forContract: contract, server: server) else { return nil }
                token = Activity.AssignedToken(tokenObject: t)
                tokensCache[contract] = token
            }

            let implicitAttributes = generateImplicitAttributesForToken(forContract: contract, server: server, symbol: token.symbol)
            let tokenAttributes = implicitAttributes
            var cardAttributes = Self.functional.generateImplicitAttributesForCard(forContract: contract, server: server, event: eachEvent)
            cardAttributes.merge(eachEvent.data) { _, new in new }

            for parameter in card.eventOrigin.parameters {
                guard let originalValue = cardAttributes[parameter.name] else { continue }
                guard let type = SolidityType(rawValue: parameter.type) else { continue }
                let translatedValue = type.coerce(value: originalValue)
                cardAttributes[parameter.name] = translatedValue
            }

            let tokenObject: Activity.AssignedToken
            let tokenHolders: [TokenHolder]
            if let (o, h) = tokensAndTokenHolders[contract] {
                tokenObject = o
                tokenHolders = h
            } else {
                tokenObject = token
                if tokenObject.contractAddress.sameContract(as: Constants.nativeCryptoAddressInDatabase) {
                    let token = Token(tokenIdOrEvent: .tokenId(tokenId: .init(1)), tokenType: .nativeCryptocurrency, index: 0, name: "", symbol: "", status: .available, values: .init())

                    tokenHolders = [TokenHolder(tokens: [token], contractAddress: tokenObject.contractAddress, hasAssetDefinition: true)]
                } else {
                    guard let t = tokensDataStore.token(forContract: contract, server: server) else { return nil }

                    tokenHolders = TokenAdaptor(token: t, assetDefinitionStore: assetDefinitionStore, eventsDataStore: eventsDataStore).getTokenHolders(forWallet: wallet)
                }
                tokensAndTokenHolders[contract] = (tokenObject: tokenObject, tokenHolders: tokenHolders)
            }
            //NOTE: using `tokenHolders[0]` i received crash with out of range exception
            guard let tokenHolder = tokenHolders.first else { return nil }
            //TODO fix for activities: special fix to filter out the event we don't want - need to doc this and have to handle with TokenScript design
            let isNativeCryptoAddress = tokenObject.contractAddress.sameContract(as: Constants.nativeCryptoAddressInDatabase)
            if card.name == "aETHMinted" && isNativeCryptoAddress && cardAttributes["amount"]?.uintValue == 0 {
                return nil
            } else {
                //no-op
            }

            let activity = Activity(id: Int.random(in: 0..<Int.max), rowType: .standalone, tokenObject: tokenObject, server: eachEvent.server, name: card.name, eventName: eachEvent.eventName, blockNumber: eachEvent.blockNumber, transactionId: eachEvent.transactionId, transactionIndex: eachEvent.transactionIndex, logIndex: eachEvent.logIndex, date: eachEvent.date, values: (token: tokenAttributes, card: cardAttributes), view: card.view, itemView: card.itemView, isBaseCard: card.isBase, state: .completed)

            return (activity: activity, tokenObject: tokenObject, tokenHolder: tokenHolder)
        }

        return activitiesForThisCard
    }

    private func reloadViewController(reloadImmediately: Bool) {
        if reloadImmediately {
            reloadViewControllerImpl()
        } else {
            //We want to show the activities tab immediately the first time activities are available, otherwise when the app launch and user goes to the tab immediately and wait for a few seconds, they'll see some of the transactions transforming into activities. Very jarring
            if hasLoadedActivitiesTheFirstTime {
                if rateLimitedViewControllerReloader == nil {
                    rateLimitedViewControllerReloader = RateLimiter(name: "Reload activity/transactions in Activity tab", limit: 5, autoRun: true) { [weak self] in
                        self?.reloadViewControllerImpl()
                    }
                } else {
                    rateLimitedViewControllerReloader?.run()
                }
            } else {
                reloadViewControllerImpl()
            }
        }
    }

    func reinject(activity: Activity) {
        guard let (token, tokenHolder) = tokensAndTokenHolders[activity.tokenObject.contractAddress] else { return }

        refreshActivity(tokenObject: token, tokenHolder: tokenHolder[0], activity: activity, isFirstUpdate: true)
    }

    private func reloadViewControllerImpl() {
        Promise<[TransactionInstance]> { seal in
            if !activities.isEmpty {
                hasLoadedActivitiesTheFirstTime = true
            }

            DispatchQueue.main.async {
                self.fetchTransactionsCancelable?.cancel()
                self.fetchTransactionsCancelable = self.transactionDataStore
                    .transactionsPublisher(forFilter: self.transactionsFilterStrategy, servers: self.config.enabledServers, oldestBlockNumber: self.activities.last?.blockNumber)
                    .replaceError(with: [])
                    .map { result -> [TransactionInstance] in
                        return result.map { TransactionInstance(transaction: $0) }
                    }
                    .receive(on: self.queue)
                    .sink { transactions in
                        seal.fulfill(transactions)
                    }
            }
        }.then(on: queue, { [weak self] transactions -> Promise<[ActivityRowModel]> in
            guard let strongSelf = self else { return .init(error: PMKError.cancelled) }

            return strongSelf.combine(activities: strongSelf.activities, withTransactions: transactions)
        }).map(on: queue, { items in
            return ActivitiesViewModel.sorted(activities: items)
        }).done(on: .main, { [weak self] activities in
            self?.subscribableViewModel.value = .init(activities: activities)
        }).cauterize()
    }

    //Combining includes filtering around activities (from events) for ERC20 send/receive transactions which are already covered by transactions
    private func combine(activities: [Activity], withTransactions transactionInstances: [TransactionInstance]) -> Promise<[ActivityRowModel]> {
        return Promise<[Int: [ActivityOrTransactionInstance]]> { seal in
            let all: [ActivityOrTransactionInstance] = activities.map { .activity($0) } + transactionInstances.map { .transaction($0) }
            let sortedAll: [ActivityOrTransactionInstance] = all.sorted { $0.blockNumber < $1.blockNumber }
            let counters = Dictionary(grouping: sortedAll, by: \.blockNumber)

            seal.fulfill(counters)
        }.map(on: .main, { [weak self] counters -> [ActivityRowModel] in
            guard let strongSelf = self else { throw PMKError.cancelled }

            return counters.map {
                strongSelf.generateRowModels(fromActivityOrTransactions: $0.value, withBlockNumber: $0.key)
            }.flatMap { $0 }
        })
    }

    private func generateRowModels(fromActivityOrTransactions activityOrTransactions: [ActivityOrTransactionInstance], withBlockNumber blockNumber: Int) -> [ActivityRowModel] {
        if activityOrTransactions.isEmpty {
            //Shouldn't be possible
            return .init()
        } else if activityOrTransactions.count > 1 {
            let activities: [Activity] = activityOrTransactions.compactMap(\.activity)
            //TODO will we ever have more than 1 transaction object (not activity/event) in the database for the same block number? Maybe if we get 1 from normal Etherscan endpoint and another from Etherscan ERC20 history endpoint?
            if let transaction: TransactionInstance = activityOrTransactions.compactMap(\.transaction).first {
                var results: [ActivityRowModel] = .init()
                let activities: [Activity] = activities.filter { activity in
                    let operations = transaction.localizedOperations
                    return operations.allSatisfy { activity != $0 }
                }
                let activity = ActivitiesViewModel.functional.createPseudoActivity(fromTransactionRow: .standalone(transaction), tokensDataStore: tokensDataStore, wallet: wallet.address)
                if transaction.localizedOperations.isEmpty && activities.isEmpty {
                    results.append(.standaloneTransaction(transaction: transaction, activity: activity))
                } else if transaction.localizedOperations.count == 1, transaction.value == "0", activities.isEmpty {
                    results.append(.standaloneTransaction(transaction: transaction, activity: activity))
                } else if transaction.localizedOperations.isEmpty && activities.count == 1 {
                    results.append(.parentTransaction(transaction: transaction, isSwap: false, activities: activities))
                    results.append(contentsOf: activities.map { .childActivity(transaction: transaction, activity: $0) })
                } else {
                    let isSwap = self.isSwap(activities: activities, operations: transaction.localizedOperations, wallet: wallet)
                    results.append(.parentTransaction(transaction: transaction, isSwap: isSwap, activities: activities))

                    results.append(contentsOf: transaction.localizedOperations.map {
                        let activity = ActivitiesViewModel.functional.createPseudoActivity(fromTransactionRow: .item(transaction: transaction, operation: $0), tokensDataStore: tokensDataStore, wallet: wallet.address)
                        return .childTransaction(transaction: transaction, operation: $0, activity: activity)
                    })
                    for each in activities {
                        results.append(.childActivity(transaction: transaction, activity: each))
                    }
                }
                return results
            } else {
                //TODO we should have a group here too to wrap activities with the same block number. No transaction, so more work
                return activities.map { .standaloneActivity(activity: $0) }
            }
        } else {
            switch activityOrTransactions.first {
            case .activity(let activity):
                return [.standaloneActivity(activity: activity)]
            case .transaction(let transaction):
                let activity = ActivitiesViewModel.functional.createPseudoActivity(fromTransactionRow: .standalone(transaction), tokensDataStore: tokensDataStore, wallet: wallet.address)
                if transaction.localizedOperations.isEmpty {
                    return [.standaloneTransaction(transaction: transaction, activity: activity)]
                } else if transaction.localizedOperations.count == 1 {
                    return [.standaloneTransaction(transaction: transaction, activity: activity)]
                } else {
                    let isSwap = self.isSwap(activities: activities, operations: transaction.localizedOperations, wallet: wallet)
                    var results: [ActivityRowModel] = .init()
                    results.append(.parentTransaction(transaction: transaction, isSwap: isSwap, activities: .init()))
                    results.append(contentsOf: transaction.localizedOperations.map {
                        let activity = ActivitiesViewModel.functional.createPseudoActivity(fromTransactionRow: .item(transaction: transaction, operation: $0), tokensDataStore: tokensDataStore, wallet: wallet.address)

                        return .childTransaction(transaction: transaction, operation: $0, activity: activity)
                    })
                    return results
                }
            case .none:
                return .init()
            }
        }
    }

    private func isSwap(activities: [Activity], operations: [LocalizedOperationObjectInstance], wallet: Wallet) -> Bool {
        //Might have other transactions like approved embedded, so we can't check for all send and receives.
        let hasSend = activities.contains { $0.isSend } || operations.contains { $0.isSend(from: wallet.address) }
        let hasReceive = activities.contains { $0.isReceive } || operations.contains { $0.isReceived(by: wallet.address) }
        return hasSend && hasReceive
    }

    //Important to pass in the `TokenHolder` instance and not re-create so that we don't override the subscribable values for the token with ones that are not resolved yet
    private func refreshActivity(tokenObject: Activity.AssignedToken, tokenHolder: TokenHolder, activity: Activity, isFirstUpdate: Bool = true) {
        let attributeValues = AssetAttributeValues(attributeValues: tokenHolder.values)
        let resolvedAttributeNameValues = attributeValues.resolve { [weak self, weak tokenHolder] _ in
            guard let strongSelf = self, let tokenHolder = tokenHolder, isFirstUpdate else { return }
            strongSelf.refreshActivity(tokenObject: tokenObject, tokenHolder: tokenHolder, activity: activity, isFirstUpdate: false)
        }

        //NOTE: Fix crush when element with index out of range
        if let (index, oldActivity) = activitiesIndexLookup[activity.id], activities.indices.contains(index) {
            let updatedValues = (token: oldActivity.values.token.merging(resolvedAttributeNameValues) { _, new in new }, card: oldActivity.values.card)
            let updatedActivity: Activity = .init(id: oldActivity.id, rowType: oldActivity.rowType, tokenObject: tokenObject, server: oldActivity.server, name: oldActivity.name, eventName: oldActivity.eventName, blockNumber: oldActivity.blockNumber, transactionId: oldActivity.transactionId, transactionIndex: oldActivity.transactionIndex, logIndex: oldActivity.logIndex, date: oldActivity.date, values: updatedValues, view: oldActivity.view, itemView: oldActivity.itemView, isBaseCard: oldActivity.isBaseCard, state: oldActivity.state)

            //Ugly, but should be safe
            executeThreadSafe({ [unowned self] in
                self.activities[index] = updatedActivity
                self.reloadViewController(reloadImmediately: false)

                self.subscribableUpdatedActivity.value = updatedActivity
            }, queue: activitiesThreadSafeQueue)
        } else {
            //no-op. We should be able to find it unless the list of activities has changed
        }
    }

    private func generateImplicitAttributesForToken(forContract contract: AlphaWallet.Address, server: RPCServer, symbol: String) -> [String: AssetInternalValue] {
        var results = [String: AssetInternalValue]()
        for each in AssetImplicitAttributes.allCases {
            //TODO ERC721s aren't fungible, but doesn't matter here
            guard each.shouldInclude(forAddress: contract, isFungible: true) else { continue }
            switch each {
            case .ownerAddress:
                results[each.javaScriptName] = .address(sessions[server].account.address)
            case .tokenId:
                //We aren't going to add `tokenId` as an implicit attribute even for ERC721s, because we don't know it
                break
            case .label:
                break
            case .symbol:
                results[each.javaScriptName] = .string(symbol)
            case .contractAddress:
                results[each.javaScriptName] = .address(contract)
            }
        }
        return results
    }

    //We can't run this in `activities` didSet {} because this will then be run unnecessarily, when we refresh each activity (we only want this to update when we refresh the entire activity list)
    private func updateActivitiesIndexLookup() {
        var arrayIndex = -1
        activitiesIndexLookup = Dictionary(uniqueKeysWithValues: activities.map {
            arrayIndex += 1
            return ($0.id, (arrayIndex, $0))
        })
    }
}
// swiftlint:enable type_body_length

fileprivate func == (activity: Activity, operation: LocalizedOperationObjectInstance) -> Bool {
    func isSameFrom() -> Bool {
        guard let from = activity.values.card["from"]?.addressValue, from.sameContract(as: operation.from) else { return false }
        return true
    }

    func isSameTo() -> Bool {
        guard let to = activity.values.card["to"]?.addressValue, to.sameContract(as: operation.to) else { return false }
        return true
    }

    func isSameAmount() -> Bool {
        guard let amount = activity.values.card["amount"]?.uintValue, String(amount) == operation.value else { return false }
        return true
    }

    guard let symbol = activity.values.token["symbol"]?.stringValue, symbol == operation.symbol else { return false }
    let sameOperation: Bool = {
        switch operation.operationType {
        case .nativeCurrencyTokenTransfer:
            //TODO not possible to hit this since we can't have an activity (event) for crypto send/received?
            return activity.nativeViewType == .nativeCryptoSent || activity.nativeViewType == .nativeCryptoReceived
        case .erc20TokenTransfer:
            return (activity.nativeViewType == .erc20Sent || activity.nativeViewType == .erc20Received) && isSameAmount() && isSameFrom() && isSameTo()
        case .erc20TokenApprove:
            return activity.nativeViewType == .erc20OwnerApproved || activity.nativeViewType == .erc20ApprovalObtained || activity.nativeViewType == .erc721OwnerApproved || activity.nativeViewType == .erc721ApprovalObtained
        case .erc721TokenTransfer, .erc1155TokenTransfer:
            return (activity.nativeViewType == .erc721Sent || activity.nativeViewType == .erc721Received) && isSameAmount() && isSameFrom() && isSameTo()
        case .erc875TokenTransfer:
            return false
        case .unknown:
            return false
        }
    }()
    guard sameOperation else { return false }
    return true
}

fileprivate func != (activity: Activity, operation: LocalizedOperationObjectInstance) -> Bool {
    !(activity == operation)
}

extension ActivitiesService {
    class functional {}
}

extension ActivitiesService.functional {
    static func generateImplicitAttributesForCard(forContract contract: AlphaWallet.Address, server: RPCServer, event: EventActivity) -> [String: AssetInternalValue] {
        var results = [String: AssetInternalValue]()
        var timestamp: GeneralisedTime = .init()
        timestamp.date = event.date
        results["timestamp"] = .generalisedTime(timestamp)
        return results
    }
}

func executeThreadSafe(_ closure: () -> Void, queue: DispatchQueue) {
    if Thread.isMainThread {
        closure()
    } else {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            closure()
        }
    }
}
