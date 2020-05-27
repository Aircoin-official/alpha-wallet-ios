// Copyright © 2018 Stormbird PTE. LTD.

import Foundation
import UIKit
import PromiseKit

protocol TokensCoordinatorDelegate: class, CanOpenURL {
    func didPress(for type: PaymentFlow, server: RPCServer, in coordinator: TokensCoordinator)
    func didTap(transaction: Transaction, inViewController viewController: UIViewController, in coordinator: TokensCoordinator)
    func openConsole(inCoordinator coordinator: TokensCoordinator)
}

private struct NoContractDetailsDetected: Error {
}

class TokensCoordinator: Coordinator {
    private let sessions: ServerDictionary<WalletSession>
    private let keystore: Keystore
    private let config: Config
    private let tokenCollection: TokenCollection
    private let nativeCryptoCurrencyPrices: ServerDictionary<Subscribable<Double>>
    private let assetDefinitionStore: AssetDefinitionStore
    private let eventsDataStore: EventsDataStoreProtocol
    private let promptBackupCoordinator: PromptBackupCoordinator
    private let filterTokensCoordinator: FilterTokensCoordinator
    private var serverToAddCustomTokenOn: RPCServerOrAuto = .auto {
        didSet {
            switch serverToAddCustomTokenOn {
            case .auto:
                break
            case .server:
                addressToAutoDetectServerFor = nil
            }
        }
    }
    private let autoDetectTransactedTokensQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Auto-detect Transacted Tokens"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let autoDetectTokensQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Auto-detect Tokens"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var tokensViewController: TokensViewController = {
        let controller = TokensViewController(
                sessions: sessions,
                account: sessions.anyValue.account,
                tokenCollection: tokenCollection,
                assetDefinitionStore: assetDefinitionStore,
                eventsDataStore: eventsDataStore,
                filterTokensCoordinator: filterTokensCoordinator
        )
        controller.delegate = self
        return controller
    }()

    private var newTokenViewController: NewTokenViewController?
    private var addressToAutoDetectServerFor: AlphaWallet.Address?

    private var singleChainTokenCoordinators: [SingleChainTokenCoordinator] {
        return coordinators.compactMap { $0 as? SingleChainTokenCoordinator }
    }

    let navigationController: UINavigationController
    var coordinators: [Coordinator] = []
    weak var delegate: TokensCoordinatorDelegate?

    lazy var rootViewController: TokensViewController = {
        return tokensViewController
    }()

    init(
            navigationController: UINavigationController = NavigationController(),
            sessions: ServerDictionary<WalletSession>,
            keystore: Keystore,
            config: Config,
            tokenCollection: TokenCollection,
            nativeCryptoCurrencyPrices: ServerDictionary<Subscribable<Double>>,
            assetDefinitionStore: AssetDefinitionStore,
            eventsDataStore: EventsDataStoreProtocol,
            promptBackupCoordinator: PromptBackupCoordinator,
            filterTokensCoordinator: FilterTokensCoordinator
    ) {
        self.filterTokensCoordinator = filterTokensCoordinator
        self.navigationController = navigationController
        self.navigationController.modalPresentationStyle = .formSheet
        self.sessions = sessions
        self.keystore = keystore
        self.config = config
        self.tokenCollection = tokenCollection
        self.nativeCryptoCurrencyPrices = nativeCryptoCurrencyPrices
        self.assetDefinitionStore = assetDefinitionStore
        self.eventsDataStore = eventsDataStore
        self.promptBackupCoordinator = promptBackupCoordinator
        promptBackupCoordinator.prominentPromptDelegate = self
        setupSingleChainTokenCoordinators()
    }

    func start() {
        for each in singleChainTokenCoordinators {
            each.start()
        }
        addDiscoveryToken()
        addUefaTokenIfAny()
        showTokens()
    }

    private func setupSingleChainTokenCoordinators() {
        for each in tokenCollection.tokenDataStores {
            let server = each.server
            let session = sessions[server]
            let price = nativeCryptoCurrencyPrices[server]
            let coordinator = SingleChainTokenCoordinator(session: session, keystore: keystore, tokensStorage: each, ethPrice: price, assetDefinitionStore: assetDefinitionStore, eventsDataStore: eventsDataStore, navigationController: navigationController, withAutoDetectTransactedTokensQueue: autoDetectTransactedTokensQueue, withAutoDetectTokensQueue: autoDetectTokensQueue)
            coordinator.delegate = self
            addCoordinator(coordinator)
        }
    }

    private func showTokens() {
        navigationController.viewControllers = [rootViewController]
    }

    func addImportedToken(forContract contract: AlphaWallet.Address, server: RPCServer) {
        guard let coordinator = singleChainTokenCoordinator(forServer: server) else { return }
        coordinator.addImportedToken(forContract: contract)
    }

    func addDiscoveryToken() {
        //Should only be on mainnet for now
        let server = RPCServer(chainID: 1)
        guard let coordinator = singleChainTokenCoordinator(forServer: server) else { return }
        coordinator.addImportedToken(forContract: Constants.discoveryContractAddress)
    }

    func addUefaTokenIfAny() {
        let server = Constants.uefaRpcServer
        guard let coordinator = singleChainTokenCoordinator(forServer: server) else { return }
        coordinator.addImportedToken(forContract: Constants.uefaMainnet, onlyIfThereIsABalance: true)
    }

    private func singleChainTokenCoordinator(forServer server: RPCServer) -> SingleChainTokenCoordinator? {
        return singleChainTokenCoordinators.first { $0.isServer(server) }
    }

    private func showServers(inViewController viewController: UIViewController) {
        let coordinator = ServersCoordinator(defaultServer: serverToAddCustomTokenOn, config: config)
        coordinator.delegate = self
        coordinator.start()
        addCoordinator(coordinator)
        let nc = UINavigationController(rootViewController: coordinator.serversViewController)
        nc.makePresentationFullScreenForiOS13Migration()
        viewController.present(nc, animated: true)
    }

    private func fetchContractDataPromise(forServer server: RPCServer, address: AlphaWallet.Address, inViewController viewController: NewTokenViewController) -> Promise<TokenType> {
        guard let coordinator = singleChainTokenCoordinator(forServer: server) else { return .init() { _ in } }
        return Promise { seal in
            coordinator.fetchContractData(for: address) { [weak self] (data) in
                guard let strongSelf = self else { return }
                guard strongSelf.addressToAutoDetectServerFor == address else { return }
                switch data {
                case .name, .symbol, .balance, .decimals:
                    break
                case .nonFungibleTokenComplete(let name, let symbol, let balance, let tokenType):
                    viewController.updateNameValue(name)
                    viewController.updateSymbolValue(symbol)
                    viewController.updateBalanceValue(balance)
                    seal.fulfill(tokenType)
                case .fungibleTokenComplete(let name, let symbol, let decimals):
                    viewController.updateNameValue(name)
                    viewController.updateSymbolValue(symbol)
                    viewController.updateDecimalsValue(decimals)
                    seal.fulfill(.erc20)
                case .delegateTokenComplete:
                    seal.reject(NoContractDetailsDetected())
                case .failed:
                    seal.reject(NoContractDetailsDetected())
                }
            }
        }
    }

    private func fetchContractData(forServer server: RPCServer, address: AlphaWallet.Address, inViewController viewController: NewTokenViewController) {
        guard let coordinator = singleChainTokenCoordinator(forServer: server) else { return }
        coordinator.fetchContractData(for: address) { data in
            switch data {
            case .name(let name):
                viewController.updateNameValue(name)
            case .symbol(let symbol):
                viewController.updateSymbolValue(symbol)
            case .balance(let balance):
                viewController.updateBalanceValue(balance)
            case .decimals(let decimals):
                viewController.updateDecimalsValue(decimals)
            case .nonFungibleTokenComplete(_, _, _, let tokenType):
                viewController.updateForm(forTokenType: tokenType)
            case .fungibleTokenComplete:
                viewController.updateForm(forTokenType: .erc20)
            case .delegateTokenComplete:
                viewController.updateForm(forTokenType: .erc20)
            case .failed:
                break
            }
        }
    }

    func listOfBadTokenScriptFilesChanged(fileNames: [TokenScriptFileIndices.FileName]) {
        tokensViewController.listOfBadTokenScriptFiles = fileNames
    }
}

extension TokensCoordinator: TokensViewControllerDelegate {
    func didPressAddHideTokens(viewModel: TokensViewModel) {
        let coordinator: AddHideTokensCoordinator = .init(
            tokens: viewModel.tokens,
            assetDefinitionStore: assetDefinitionStore,
            filterTokensCoordinator: filterTokensCoordinator,
            tickers: viewModel.tickers,
            sessions: sessions,
            navigationController: navigationController,
            tokenCollection: tokenCollection,
            config: config,
            singleChainTokenCoordinators: singleChainTokenCoordinators
        )
        coordinator.delegate = self
        addCoordinator(coordinator)
        coordinator.start()
    }

    func didSelect(token: TokenObject, in viewController: UIViewController) {
        let server = token.server
        guard let coordinator = singleChainTokenCoordinator(forServer: server) else { return }
        switch token.type {
        case .nativeCryptocurrency:
            coordinator.show(fungibleToken: token, transferType: .nativeCryptocurrency(server: server, destination: .none, amount: nil))
        case .erc20:
            coordinator.show(fungibleToken: token, transferType: .ERC20Token(token, destination: nil, amount: nil))
        case .erc721:
            coordinator.showTokenList(for: .send(type: .ERC721Token(token)), token: token)
        case .erc875, .erc721ForTickets:
            coordinator.showTokenList(for: .send(type: .ERC875Token(token)), token: token)
        }
    }

    func didHide(token: TokenObject, in viewController: UIViewController) {
        guard let coordinator = singleChainTokenCoordinator(forServer: token.server) else { return }
        coordinator.mark(token: token, isHidden: true)
    }

    func didTapOpenConsole(in viewController: UIViewController) {
        delegate?.openConsole(inCoordinator: self)
    }
}

func -<T: Equatable>(left: [T], right: [T]) -> [T] {
    return left.filter { l in
        !right.contains { $0 == l }
    }
}

extension TokensCoordinator: SingleChainTokenCoordinatorDelegate {
    func tokensDidChange(inCoordinator coordinator: SingleChainTokenCoordinator) {
        tokensViewController.fetch()
    }

    func didPress(for type: PaymentFlow, inCoordinator coordinator: SingleChainTokenCoordinator) {
        delegate?.didPress(for: type, server: coordinator.session.server, in: self)
    }

    func didTap(transaction: Transaction, inViewController viewController: UIViewController, in coordinator: SingleChainTokenCoordinator) {
        delegate?.didTap(transaction: transaction, inViewController: viewController, in: self)
    }
}

extension TokensCoordinator: CanOpenURL {
    func didPressViewContractWebPage(forContract contract: AlphaWallet.Address, server: RPCServer, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(forContract: contract, server: server, in: viewController)
    }

    func didPressViewContractWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressViewContractWebPage(url, in: viewController)
    }

    func didPressOpenWebPage(_ url: URL, in viewController: UIViewController) {
        delegate?.didPressOpenWebPage(url, in: viewController)
    }
}

extension TokensCoordinator: ServersCoordinatorDelegate {
    func didSelectServer(server: RPCServerOrAuto, in coordinator: ServersCoordinator) {
        serverToAddCustomTokenOn = server
        coordinator.serversViewController.navigationController?.dismiss(animated: true) { [weak self] in
            guard let strongSelf = self else { return }
            guard let vc = strongSelf.newTokenViewController else { return }
            vc.server = strongSelf.serverToAddCustomTokenOn
            vc.configure()
            vc.redetectToken()
        }
        removeCoordinator(coordinator)
    }

    func didSelectDismiss(in coordinator: ServersCoordinator) {
        coordinator.serversViewController.navigationController?.dismiss(animated: true)
        removeCoordinator(coordinator)
    }
}

extension TokensCoordinator: PromptBackupCoordinatorProminentPromptDelegate {
    var viewControllerToShowBackupLaterAlert: UIViewController {
        return tokensViewController
    }

    func updatePrompt(inCoordinator coordinator: PromptBackupCoordinator) {
        tokensViewController.promptBackupWalletView = coordinator.prominentPromptView
    }
}

extension TokensCoordinator: AddHideTokensCoordinatorDelegate {
    func didClose(coordinator: AddHideTokensCoordinator) {
        removeCoordinator(coordinator)
    }
}
