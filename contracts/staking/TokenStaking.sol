// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.4;

import "./IStaking.sol";
import "./StakingProviders.sol";
import "./IApplication.sol";
import "../token/T.sol";
import "../vending/VendingMachine.sol";
import "../utils/PercentUtils.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Meta staking contract. 3 roles: app, meta staking, app manager
contract TokenStaking is Ownable, IStaking {
    using SafeERC20 for T;
    using PercentUtils for uint256;

    enum StakingProvider {
        NU,
        KEEP,
        T
    }

    struct OperatorInfo {
        address owner;
        address payable beneficiary;
        address authorizer;
        mapping(address => AppAuthorization) authorizations;
        address[] authorizedApplications;
        uint256 nuStake;
        uint256 keepStake;
        uint256 tStake;
        uint256 startTStakingTimestamp;
    }

    struct AppAuthorization {
        uint256 authorized;
        uint256 deauthorizing;
    }

    struct ApplicationInfo {
        bool approved;
        bool disabled;
        address panicButton;
    }

    struct SlashingEvent {
        address operator;
        uint256 amount; // TODO uint256 -> uint96
        // address notifier;
        // uint256 rewardMultiplier;
    }

    uint256 public constant SLASHING_REWARD_PERCENT = 5;
    uint256 public constant MIN_STAKE_TIME = 24 hours;

    T public immutable token;
    IKeepTokenStaking public immutable keepStakingContract;
    INuCypherStakingEscrow public immutable nucypherStakingContract;
    VendingMachine public immutable keepVendingMachine;
    VendingMachine public immutable nucypherVendingMachine;

    uint256 public minTStakeAmount;
    uint256 public authorizationCeiling;
    uint256 public stakeDiscrepancyPenalty;
    uint256 public stakeDiscrepancyRewardMultiplier;

    uint256 public notifiersTreasury;
    uint256 public notificationReward;

    // TODO public getters for inner mappings
    mapping(address => OperatorInfo) public operators;
    mapping(address => ApplicationInfo) public applicationInfo;
    address[] public applications;

    SlashingEvent[] public slashingQueue;
    uint256 public slashingQueueIndex = 0;

    event TStaked(address indexed owner, address indexed operator);
    event KeepStaked(address indexed owner, address indexed operator);
    event NuStaked(address indexed owner, address indexed operator);
    event OperatorStaked(
        address indexed operator,
        address indexed beneficiary,
        address indexed authorizer,
        uint256 amount
    );
    event MinimumStakeAmountSet(uint256 amount);
    event ApplicationApproved(address indexed application);
    event AuthorizationIncreased(
        address indexed operator,
        address indexed application,
        uint256 amount
    );
    event AuthorizationDecreaseRequested(
        address indexed operator,
        address indexed application,
        uint256 amount
    );
    event AuthorizationDecreaseApproved(
        address indexed operator,
        address indexed application,
        uint256 amount
    );
    event ApplicationDisabled(address indexed application);
    event PanicButtonSet(
        address indexed application,
        address indexed panicButton
    );
    event AuthorizationCeilingSet(uint256 ceiling);
    event ToppedUp(address indexed operator, uint256 amount);
    event Unstaked(address indexed operator, uint256 amount);
    event TokensSeized(address indexed operator, uint256 amount);
    event StakeDiscrepancyPenaltySet(uint256 penalty, uint256 rewardMultiplier);
    event NotificationRewardSet(uint256 reward);
    event NotificationRewardPushed(uint256 reward);
    event NotifierRewarded(address indexed notifier, uint256 amount);

    // modifier onlyOperatorsOwner(address operator) {
    //     require(
    //         operators[operator].owner == msg.sender,
    //         "Only owner can call this function"
    //     );
    //     _;
    // }

    modifier onlyGovernance() {
        require(owner() == msg.sender, "Caller is not the governance");
        _;
    }

    modifier onlyPanicButtonOf(address application) {
        require(
            applicationInfo[application].panicButton == msg.sender,
            "Caller is not the address of panic button"
        );
        _;
    }

    modifier onlyAuthorizerOf(address operator) {
        require(
            operators[operator].authorizer == msg.sender,
            "Not operator authorizer"
        );
        _;
    }

    /// @param _token Address of T token contract
    /// @param _keepStakingContract Address of Keep staking contract
    /// @param _nucypherStakingContract Address of NuCypher staking contract
    /// @param _keepVendingMachine Address of Keep vending machine
    /// @param _nucypherVendingMachine Address of NuCypher vending machine
    constructor(
        T _token,
        IKeepTokenStaking _keepStakingContract,
        INuCypherStakingEscrow _nucypherStakingContract,
        VendingMachine _keepVendingMachine,
        VendingMachine _nucypherVendingMachine
    ) {
        // TODO check contracts and input variables
        token = _token;
        keepStakingContract = _keepStakingContract;
        nucypherStakingContract = _nucypherStakingContract;
        keepVendingMachine = _keepVendingMachine;
        nucypherVendingMachine = _nucypherVendingMachine;
    }

    //
    //
    // Delegating a stake
    //
    //

    /// @notice Creates a delegation with `msg.sender` owner with the given
    ///         operator, beneficiary, and authorizer. Transfers the given
    ///         amount of T to the staking contract.
    /// @dev The owner of the delegation needs to have the amount approved to
    ///      transfer to the staking contract.
    function stake(
        address _operator,
        address payable _beneficiary,
        address _authorizer,
        uint256 _amount
    ) external override {
        require(_operator != address(0), "Operator must be specified");
        OperatorInfo storage operator = operators[_operator];
        (, uint256 createdAt, ) = keepStakingContract.getDelegationInfo(
            _operator
        );
        require(
            createdAt == 0 && operator.owner == address(0),
            "Operator is already in use"
        );
        require(
            _amount > minTStakeAmount,
            "Amount to stake must be greater than 0"
        );
        operator.owner = msg.sender;
        operator.authorizer = _authorizer != address(0)
            ? _authorizer
            : msg.sender;
        operator.beneficiary = _beneficiary != address(0)
            ? _beneficiary
            : payable(msg.sender);

        operator.tStake = _amount;
        /* solhint-disable-next-line not-rely-on-time */
        operator.startTStakingTimestamp = block.timestamp;

        emit TStaked(msg.sender, _operator);
        emit OperatorStaked(_operator, _beneficiary, _authorizer, _amount);
        token.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /// @notice Copies delegation from the legacy KEEP staking contract to T
    ///         staking contract. No tokens are transferred. Caches the active
    ///         stake amount from KEEP staking contract. Can be called by
    ///         anyone.
    function stakeKeep(address _operator) external override {
        require(_operator != address(0), "Operator must be specified");
        OperatorInfo storage operator = operators[_operator];

        require(
            operator.owner == address(0),
            "Can't stake KEEP for this operator"
        );

        (
            uint256 keepStakeAmount,
            uint256 createdAt,
            uint256 undelegatedAt
        ) = keepStakingContract.getDelegationInfo(_operator);
        require(createdAt != 0, "Nothing to sync");

        require(
            keepStakingContract.isAuthorizedForOperator(
                _operator,
                address(this)
            ),
            "T staking contract is not authorized in Keep contract"
        );
        uint256 tAmount = 0;
        if (undelegatedAt == 0) {
            (tAmount, ) = keepVendingMachine.conversionToT(keepStakeAmount);
        }

        operator.keepStake = tAmount;
        operator.owner = keepStakingContract.ownerOf(_operator);
        operator.authorizer = keepStakingContract.authorizerOf(_operator);
        operator.beneficiary = keepStakingContract.beneficiaryOf(_operator);
        emit KeepStaked(operator.owner, _operator);
        emit OperatorStaked(
            _operator,
            operator.beneficiary,
            operator.authorizer,
            tAmount
        );
    }

    /// @notice Copies delegation from the legacy NU staking contract to T
    ///         staking contract, additionally appointing beneficiary and
    ///         authorizer roles. Caches the amount staked in NU staking
    ///         contract. Can be called only by the original delegation owner.
    function stakeNu(
        address _operator,
        address payable _beneficiary,
        address _authorizer
    ) external override {
        require(_operator != address(0), "Operator must be specified");
        OperatorInfo storage operator = operators[_operator];
        (, uint256 createdAt, ) = keepStakingContract.getDelegationInfo(
            _operator
        );
        require(
            createdAt == 0 && operator.owner == address(0),
            "Operator is already in use"
        );

        uint256 nuStakeAmount = nucypherStakingContract.requestMerge(
            msg.sender
        );
        (uint256 tAmount, ) = nucypherVendingMachine.conversionToT(
            nuStakeAmount
        );
        require(tAmount > 0, "Nothing to sync");

        operator.nuStake = tAmount;
        operator.owner = msg.sender;
        operator.authorizer = _authorizer;
        operator.beneficiary = _beneficiary;

        emit NuStaked(msg.sender, _operator);
        emit OperatorStaked(_operator, _beneficiary, _authorizer, tAmount);
    }

    /// @notice Allows the Governance to set the minimum required stake amount.
    ///         This amount is required to protect against griefing the staking
    ///         contract and individual applications are allowed to require
    ///         higher minimum stakes if necessary.
    function setMinimumStakeAmount(uint256 amount)
        external
        override
        onlyGovernance
    {
        minTStakeAmount = amount;
        emit MinimumStakeAmountSet(amount);
    }

    // /// @notice Set or change authorizer role
    // function setAuthorizer(address operator, address authorizer)
    //     external
    //     onlyOperatorsOwner(operator)
    // {
    //     operators[operator].authorizer = authorizer != address(0)
    //         ? authorizer
    //         : msg.sender;
    // }

    // /// @notice Set or change beneficiary role
    // function setBeneficiary(address operator, address beneficiary)
    //     external
    //     onlyOperatorsOwner(operator)
    // {
    //     operators[operator].beneficiary = beneficiary != address(0)
    //         ? beneficiary
    //         : msg.sender;
    // }

    //
    //
    // Authorizing an application
    //
    //

    /// @notice Allows the Governance to approve the particular application
    ///         before individual stake authorizers are able to authorize it.
    function approveApplication(address application)
        external
        override
        onlyGovernance
    {
        ApplicationInfo storage info = applicationInfo[application];
        info.approved = true;
        info.disabled = false;

        bool existingApplication = false;
        for (uint256 i = 0; i < applications.length; i++) {
            if (applications[i] == application) {
                existingApplication = true;
                break;
            }
        }
        if (!existingApplication) {
            applications.push(application);
        }
        emit ApplicationApproved(application);
    }

    /// @notice Increases the authorization of the given operator for the given
    ///         application by the given amount. Can only be called by the given
    ///         operator’s authorizer.
    /// @dev Calls `authorizationIncreased(address operator, uint256 amount)`
    ///      on the given application to notify the application about
    ///      authorization change. See `IApplication`.
    function increaseAuthorization(
        address _operator,
        address _application,
        uint256 _amount
    ) external override onlyAuthorizerOf(_operator) {
        ApplicationInfo storage application = applicationInfo[_application];
        require(application.approved, "Application is not approved");
        require(!application.disabled, "Application is disabled"); // TODO ?

        OperatorInfo storage operator = operators[_operator];
        AppAuthorization storage authorization = operator.authorizations[
            _application
        ];
        if (authorization.authorized == 0) {
            require(
                authorizationCeiling == 0 ||
                    operator.authorizedApplications.length <
                    authorizationCeiling,
                "Can't authorize more applications"
            );
            operator.authorizedApplications.push(_application);
        }

        uint256 availableTValue = getAvailableToAuthorize(
            _operator,
            _application
        );
        require(availableTValue >= _amount, "Not enough stake to authorize");
        authorization.authorized += _amount;
        emit AuthorizationIncreased(_operator, _application, _amount);
        IApplication(_application).authorizationIncreased(_operator, _amount);
    }

    /// @notice Requests decrease of the authorization for the given operator on
    ///         the given application by all authorized amount.
    ///         It may not change the authorized amount immediatelly. When
    ///         it happens depends on the application. Can only be called by the
    ///         given operator’s authorizer. Overwrites pending authorization
    ///         decrease for the given operator and application.
    /// @dev Calls `authorizationDecreaseRequested(address operator, uint256 amount)`
    ///      on the given application. See `IApplication`.
    function requestAuthorizationDecrease(address operator, address application)
        external
    {
        uint256 authorized = operators[operator]
            .authorizations[application]
            .authorized;
        requestAuthorizationDecrease(operator, application, authorized);
    }

    /// @notice Requests decrease of the all authorizations for the given operator on
    ///         the all applications by all authorized amount.
    ///         It may not change the authorized amount immediatelly. When
    ///         it happens depends on the application. Can only be called by the
    ///         given operator’s authorizer. Overwrites pending authorization
    ///         decrease for the given operator and application.
    /// @dev Calls `authorizationDecreaseRequested(address operator, uint256 amount)`
    ///      for each authorized application. See `IApplication`.
    function requestAuthorizationDecrease(address _operator) external {
        OperatorInfo storage operator = operators[_operator];
        uint256 deauthorizing = 0;
        for (uint256 i = 0; i < operator.authorizedApplications.length; i++) {
            address application = operator.authorizedApplications[i];
            uint256 authorized = operator
                .authorizations[application]
                .authorized;
            if (authorized > 0) {
                requestAuthorizationDecrease(
                    _operator,
                    application,
                    authorized
                );
                deauthorizing += authorized;
            }
        }

        require(deauthorizing > 0, "Nothing was authorized");
    }

    /// @notice Called by the application at its discretion to approve the
    ///         previously requested authorization decrease request. Can only be
    ///         called by the application that was previously requested to
    ///         decrease the authorization for that operator.
    function approveAuthorizationDecrease(address _operator) external override {
        ApplicationInfo storage application = applicationInfo[msg.sender];
        require(!application.disabled, "Application is disabled"); // TODO ?

        OperatorInfo storage operator = operators[_operator];
        AppAuthorization storage authorization = operator.authorizations[
            msg.sender
        ];
        require(
            authorization.deauthorizing > 0,
            "There is no deauthorizing in process"
        );

        emit AuthorizationDecreaseApproved(
            _operator,
            msg.sender,
            authorization.deauthorizing
        );
        authorization.authorized -= authorization.deauthorizing;
        authorization.deauthorizing = 0;

        // remove application from an array
        if (authorization.authorized == 0) {
            uint256 length = operator.authorizedApplications.length;
            for (uint256 index = 0; index < length - 1; index++) {
                if (operator.authorizedApplications[index] == msg.sender) {
                    operator.authorizedApplications[index] = operator
                        .authorizedApplications[length - 1];
                    break;
                }
            }
            operator.authorizedApplications.pop();
        }
    }

    /// @notice Disables the given application’s eligibility to slash stakes.
    ///         Can be called only by the Panic Button of the particular
    ///         application. The disabled application can not slash stakes until
    ///         it is approved again by the Governance using `approveApplication`
    ///         function. Should be used only in case of an emergency.
    function disableApplication(address application)
        external
        override
        onlyPanicButtonOf(application)
    {
        applicationInfo[application].disabled = true;
        emit ApplicationDisabled(application);
    }

    /// @notice Sets the Panic Button role for the given application to the
    ///         provided address. Can only be called by the Governance. If the
    ///         Panic Button for the given application should be disabled, the
    ///         role address should can set to 0x0 address.
    function setPanicButton(address application, address panicButton)
        external
        override
        onlyGovernance
    {
        applicationInfo[application].panicButton = panicButton;
        emit PanicButtonSet(application, panicButton);
    }

    /// @notice Sets the maximum number of applications one operator can
    ///         authorize. Used to protect against DoSing slashing queue.
    ///         Can only be called by the Governance.
    function setAuthorizationCeiling(uint256 ceiling)
        external
        override
        onlyGovernance
    {
        authorizationCeiling = ceiling;
        emit AuthorizationCeilingSet(ceiling);
    }

    //
    //
    // Stake top-up
    //
    //

    /// @notice Increases the amount of the stake for the given operator.
    ///         Can be called by anyone.
    /// @dev The sender of this transaction needs to have the amount approved to
    ///      transfer to the staking contract.
    function topUp(address _operator, uint256 _amount) external override {
        require(_amount > 0, "Amount to top-up must be greater than 0");
        OperatorInfo storage operator = operators[_operator];
        require(operator.owner != address(0), "Operator has no stake");
        operator.tStake += _amount;
        emit ToppedUp(_operator, _amount);
        token.safeTransferFrom(msg.sender, address(this), _amount);
    }

    /// @notice Propagates information about stake top-up from the legacy KEEP
    ///         staking contract to T staking contract. Can be called by anyone.
    function topUpKeep(address _operator) external override {
        OperatorInfo storage operator = operators[_operator];
        require(
            operator.owner != address(0),
            "Operator is not synced with Keep staking contract"
        );

        // TODO extract to internal method
        (
            uint256 keepStakeAmount,
            uint256 createdAt,
            uint256 undelegatedAt
        ) = keepStakingContract.getDelegationInfo(_operator);
        require(createdAt != 0, "Nothing to sync");

        require(
            keepStakingContract.isAuthorizedForOperator(
                _operator,
                address(this)
            ),
            "T staking contract is not authorized in Keep contract"
        );
        uint256 tAmount = 0;
        if (undelegatedAt == 0) {
            (tAmount, ) = keepVendingMachine.conversionToT(keepStakeAmount);
        }
        require(
            tAmount > operator.keepStake,
            "Amount in Keep contract is equal to or less than the stored amount"
        );

        emit ToppedUp(_operator, tAmount - operator.keepStake);
        operator.keepStake = tAmount;
    }

    /// @notice Propagates information about stake top-up from the legacy NU
    ///         staking contract to T staking contract. Can be called by anyone.
    function topUpNu(address _operator) external override {
        OperatorInfo storage operator = operators[_operator];
        require(
            operator.owner != address(0),
            "Operator is not synced with NuCypher staking contract"
        );

        uint256 nuStakeAmount = nucypherStakingContract.requestMerge(
            operator.owner
        );
        (uint256 tAmount, ) = nucypherVendingMachine.conversionToT(
            nuStakeAmount
        );
        require(
            tAmount > operator.nuStake,
            "Amount in NuCypher contract is equal to or less than the stored amount"
        );

        emit ToppedUp(_operator, tAmount - operator.nuStake);
        operator.nuStake = tAmount;
    }

    //
    //
    // Undelegating a stake (unstaking)
    //
    //

    /// @notice Reduces the liquid T stake amount by the provided amount and
    ///         withdraws T to the owner. Reverts if there is at least one
    ///         authorization higher than the sum of the legacy stake and
    ///         remaining liquid T stake or if the unstake amount is higher than
    ///         the liquid T stake amount. Can be called only by the owner or
    ///         operator.
    function unstakeT(address _operator, uint256 _amount) external override {
        OperatorInfo storage operator = operators[_operator];
        require(
            operator.owner == msg.sender || _operator == msg.sender,
            "Only owner and operator can unstake tokens"
        );
        require(
            _amount > 0 &&
                _amount + getMinStaked(_operator, StakingProvider.T) <=
                operator.tStake,
            "Can't unstake specified amount of tokens"
        );
        operator.tStake -= _amount;
        require(
            operator.tStake >= minTStakeAmount ||
                operator.startTStakingTimestamp + MIN_STAKE_TIME <=
                /* solhint-disable-next-line not-rely-on-time */
                block.timestamp,
            "Unstaking is possible only after 24 hours"
        );
        emit Unstaked(_operator, _amount);
        token.safeTransfer(operator.owner, _amount);
    }

    /// @notice Sets the legacy KEEP staking contract active stake amount cached
    ///         in T staking contract to 0. Reverts if the amount of liquid T
    ///         staked in T staking contract is lower than the highest
    ///         application authorization. This function allows to unstake from
    ///         KEEP staking contract and sill being able to operate in T
    ///         network and earning rewards based on the liquid T staked. Can be
    ///         called only by the delegation owner and operator.
    function unstakeKeep(address _operator) external override {
        OperatorInfo storage operator = operators[_operator];
        require(
            operator.owner == msg.sender || _operator == msg.sender,
            "Only owner and operator can unstake tokens"
        );
        require(operator.keepStake != 0, "Nothing to unstake");
        require(
            getMinStaked(_operator, StakingProvider.KEEP) == 0,
            "At least one application prevents from unstaking"
        );
        emit Unstaked(_operator, operator.keepStake);
        operator.keepStake = 0;
    }

    /// @notice Reduces cached legacy NU stake amount by the provided amount.
    ///         Reverts if there is at least one authorization higher than the
    ///         sum of remaining legacy NU stake and liquid T stake for that
    ///         operator or if the untaked amount is higher than the cached
    ///         legacy stake amount. If succeeded, the legacy NU stake can be
    ///         partially or fully undelegated on the legacy staking contract.
    ///         This function allows to unstake from NU staking contract and
    ///         still being able to operate in T network and earning rewards
    ///         based on the liquid T staked. Can be called only by the
    ///         delegation owner and operator.
    function unstakeNu(address _operator, uint256 _amount) external override {
        OperatorInfo storage operator = operators[_operator];
        require(
            operator.owner == msg.sender || _operator == msg.sender,
            "Only owner and operator can unstake tokens"
        );
        require(
            _amount > 0 &&
                _amount + getMinStaked(_operator, StakingProvider.NU) <=
                operator.nuStake,
            "Can't unstake specified amount of tokens"
        );
        operator.nuStake -= _amount;
        emit Unstaked(_operator, _amount);
    }

    /// @notice Sets cached legacy stake amount to 0, sets the liquid T stake
    ///         amount to 0 and withdraws all liquid T from the stake to the
    ///         owner. Reverts if there is at least one non-zero authorization.
    ///         Can be called only by the delegation owner and operator.
    function unstakeAll(address _operator) external override {
        OperatorInfo storage operator = operators[_operator];
        require(
            operator.owner == msg.sender || _operator == msg.sender,
            "Only owner and operator can unstake tokens"
        );
        require(
            operator.authorizedApplications.length == 0,
            "At least one application is still authorized"
        );

        emit Unstaked(
            _operator,
            operator.tStake + operator.keepStake + operator.nuStake
        );
        uint256 amount = operator.tStake;
        operator.tStake = 0;
        operator.keepStake = 0;
        operator.nuStake = 0;
        if (amount > 0) {
            token.safeTransfer(operator.owner, amount);
        }
    }

    //
    //
    // Keeping information in sync
    //
    //

    /// @notice Notifies about the discrepancy between legacy KEEP active stake
    ///         and the amount cached in T staking contract. Slashes the operator
    ///         in case the amount cached is higher than the actual active stake
    ///         amount in KEEP staking contract. Needs to update authorizations
    ///         of all affected applications and execute an involuntary
    ///         allocation decrease on all affected applications. Can be called
    ///         by anyone, notifier receives a reward.
    function notifyKeepStakeDiscrepancy(address _operator) external override {
        OperatorInfo storage operator = operators[_operator];
        require(operator.keepStake > 0, "Nothing to slash");

        (uint256 keepStakeAmount, , uint256 undelegatedAt) = keepStakingContract
            .getDelegationInfo(_operator);

        if (operator.keepStake > keepStakeAmount || undelegatedAt != 0) {
            (uint256 keepPenalty, ) = keepVendingMachine.conversionFromT(
                stakeDiscrepancyPenalty
            );
            // TODO extract
            address[] memory operatorWrapper = new address[](1); //new address[](1);
            operatorWrapper[0] = _operator;
            keepStakingContract.seize(
                keepPenalty,
                stakeDiscrepancyRewardMultiplier,
                msg.sender,
                operatorWrapper
            );
        } else {
            revert("There is no discrepancy");
        }

        uint256 oldKeepStake = operator.keepStake;
        if (undelegatedAt == 0) {
            (operator.keepStake, , ) = keepStakingContract.getDelegationInfo(
                _operator
            );
        } else {
            operator.keepStake = 0;
        }
        emit TokensSeized(_operator, oldKeepStake - operator.keepStake);

        authorizationDecrease(_operator, operator);
    }

    /// @notice Notifies about the discrepancy between legacy NU active stake
    ///         and the amount cached in T staking contract. Slashes the
    ///         operator in case the amount cached is higher than the actual
    ///         active stake amount in NU staking contract. Needs to update
    ///         authorizations of all affected applications and execute an
    ///         involuntary allocation decrease on all affected applications.
    ///         Can be called by anyone, notifier receives a reward.
    function notifyNuStakeDiscrepancy(address _operator) external override {
        OperatorInfo storage operator = operators[_operator];
        require(operator.nuStake > 0, "Nothing to slash");

        uint256 nuStakeAmount = nucypherStakingContract.getAllTokens(
            operator.owner
        );

        if (operator.nuStake > nuStakeAmount) {
            (uint256 nuPenalty, ) = nucypherVendingMachine.conversionFromT(
                stakeDiscrepancyPenalty
            );
            nucypherStakingContract.slashStaker(
                operator.owner,
                nuPenalty,
                msg.sender,
                nuPenalty.percent(SLASHING_REWARD_PERCENT).percent(stakeDiscrepancyRewardMultiplier)
            );
            uint256 oldNuStake = operator.nuStake;
            operator.nuStake = nuStakeAmount - nuPenalty;
            emit TokensSeized(_operator, oldNuStake - operator.nuStake);
        } else {
            revert("There is no discrepancy");
        }

        authorizationDecrease(_operator, operator);
    }

    /// @notice Sets the penalty amount for stake discrepancy and reward
    ///         multiplier for reporting it. The penalty is seized from the
    ///         operator account, and 5% of the penalty, scaled by the
    ///         multiplier, is given to the notifier. The rest of the tokens are
    ///         burned. Can only be called by the Governance. See `seize` function.
    function setStakeDiscrepancyPenalty(
        uint256 penalty,
        uint256 rewardMultiplier
    ) external override onlyGovernance {
        stakeDiscrepancyPenalty = penalty;
        stakeDiscrepancyRewardMultiplier = rewardMultiplier;
        emit StakeDiscrepancyPenaltySet(penalty, rewardMultiplier);
    }

    /// @notice Sets reward in T tokens for notification of misbehaviour of one operator
    function setNotificationReward(uint256 reward) external onlyGovernance {
        notificationReward = reward;
        emit NotificationRewardSet(reward);
    }

    /// @notice Transfer some amount of T tokens as reward for notifications of misbehaviour
    function pushNotificationReward(uint256 reward) external {
        notifiersTreasury += reward;
        emit NotificationRewardPushed(reward);
        token.safeTransferFrom(msg.sender, address(this), reward);
    }

    /// @notice Adds operators to the slashing queue along with the amount that
    ///         should be slashed from each one of them. Can only be called by
    ///         application authorized for all operators in the array.
    function slash(uint256 amount, address[] memory _operators)
        external
        override
    {
        _seize(amount, 0, address(0), _operators);
    }

    /// @notice Adds operators to the slashing queue along with the amount,
    ///         reward multiplier and notifier address. The notifier will
    ///         receive 1% of the slashed amount scaled by the reward adjustment
    ///         parameter once the seize order will be processed. Can only be
    ///         called by application authorized for all operators in the array.
    function seize(
        uint256 amount,
        uint256 rewardMultiplier,
        address notifier,
        address[] memory _operators
    ) external override {
        _seize(amount, rewardMultiplier, notifier, _operators);
    }

    /// @notice Takes the given number of queued slashing operations and
    ///         processes them. Receives 5% of the slashed amount if the
    ///         slashing request was created by the application with a slash
    ///         call and 4% of the slashed amount if the slashing request was
    ///         created by the application with seize call.
    ///         Executes `involuntaryAllocationDecrease` function on each
    ///         affected application.
    function processSlashing(uint256 count) external override {
        require(
            slashingQueueIndex < slashingQueue.length,
            "Nothing to process"
        );

        uint256 maxIndex = slashingQueueIndex + count;
        uint256 tAmountToBurn = 0;
        for (
            ;
            slashingQueueIndex < slashingQueue.length &&
                slashingQueueIndex <= maxIndex;
            slashingQueueIndex++
        ) {
            SlashingEvent storage slashing = slashingQueue[slashingQueueIndex];
            tAmountToBurn += processSlashing(slashing);
        }

        uint256 tProcessorReward = tAmountToBurn.percent(SLASHING_REWARD_PERCENT);
        notifiersTreasury += tAmountToBurn - tProcessorReward;
        token.safeTransfer(msg.sender, tProcessorReward);
    }

    //
    //
    // Auxiliary functions
    //
    //

    /// @notice Returns the authorized stake amount of the operator for the
    ///         application.
    function authorizedStake(address operator, address application)
        external
        view
        override
        returns (uint256)
    {
        return operators[operator].authorizations[application].authorized;
    }

    /// @notice Returns staked amount of NU for the specified operator
    function stakedNu(address operator)
        external
        view
        returns (uint256 nuAmount)
    {
        (nuAmount, ) = nucypherVendingMachine.conversionFromT(
            operators[operator].nuStake
        );
    }

    /// @notice Gets the beneficiary for the specified operator address.
    /// @return Beneficiary address.
    function beneficiaryOf(address operator)
        external
        view
        returns (address payable)
    {
        return operators[operator].beneficiary;
    }

    /// @notice Checks if the specified operator has a stake delegated and if it
    ///         has been authorized for at least one application. If this
    ///         function returns true, off-chain client of the given operator is
    ///         eligible to join the network.
    function hasStakeDelegated(address operator)
        external
        view
        override
        returns (bool)
    {
        return operators[operator].authorizedApplications.length > 0;
    }

    /// @notice Requests decrease of the authorization for the given operator on
    ///         the given application by the provided amount.
    ///         It may not change the authorized amount immediatelly. When
    ///         it happens depends on the application. Can only be called by the
    ///         given operator’s authorizer. Overwrites pending authorization
    ///         decrease for the given operator and application.
    /// @dev Calls `authorizationDecreaseRequested(address operator, uint256 amount)`
    ///      on the given application. See `IApplication`.
    function requestAuthorizationDecrease(
        address _operator,
        address _application,
        uint256 _amount
    ) public override onlyAuthorizerOf(_operator) {
        ApplicationInfo storage application = applicationInfo[_application];
        require(!application.disabled, "Application is disabled"); // TODO ?

        require(
            _amount > 0,
            "Amount to decrease authorization must greater than 0"
        );

        AppAuthorization storage authorization = operators[_operator]
            .authorizations[_application];
        require(
            authorization.authorized >= _amount,
            "Amount to decrease must be less than authorized"
        );

        authorization.deauthorizing = _amount;
        emit AuthorizationDecreaseRequested(_operator, _application, _amount);
        IApplication(_application).authorizationDecreaseRequested(
            _operator,
            _amount
        );
    }

    /// @notice Returns minimum possible stake for T, KEEP or NU
    function getMinStaked(address _operator, StakingProvider stakingProviders)
        public
        view
        returns (uint256)
    {
        OperatorInfo storage operator = operators[_operator];
        uint256 maxAuthorization = 0;
        for (uint256 i = 0; i < operator.authorizedApplications.length; i++) {
            address application = operator.authorizedApplications[i];
            maxAuthorization = Math.max(
                maxAuthorization,
                operator.authorizations[application].authorized
            );
        }

        if (maxAuthorization == 0) {
            return 0;
        }
        if (stakingProviders != StakingProvider.T) {
            maxAuthorization -= Math.min(maxAuthorization, operator.tStake);
        }
        if (stakingProviders != StakingProvider.NU) {
            maxAuthorization -= Math.min(maxAuthorization, operator.nuStake);
        }
        if (stakingProviders != StakingProvider.KEEP) {
            maxAuthorization -= Math.min(maxAuthorization, operator.keepStake);
        }
        return maxAuthorization;
    }

    /// @notice Returns available amount to authorize for the specified application
    function getAvailableToAuthorize(address _operator, address application)
        public
        view
        returns (uint256 availableTValue)
    {
        OperatorInfo storage operator = operators[_operator];
        availableTValue =
            operator.tStake +
            operator.keepStake +
            operator.nuStake;
        availableTValue -= operator.authorizations[application].authorized;
    }

    /// @notice Adds operators to the slashing queue along with the amount,
    ///         reward multiplier and notifier address. The notifier will
    ///         receive 1% of the slashed amount scaled by the reward adjustment
    ///         parameter once the seize order will be processed. Can only be
    ///         called by application authorized for all operators in the array.
    function _seize(
        uint256 amount,
        uint256 rewardMultiplier,
        address notifier,
        address[] memory _operators
    ) internal {
        require(
            amount > 0 && _operators.length > 0,
            "Specify amount and operators to slash"
        );

        ApplicationInfo storage application = applicationInfo[msg.sender];
        require(application.approved, "Application is not approved");
        require(!application.disabled, "Application is disabled");

        for (uint256 i = 0; i < _operators.length; ) {
            address operator = _operators[i];
            require(
                operators[operator].authorizations[msg.sender].authorized >=
                    amount,
                "Operator didn't authorize sufficient amount for application"
            );
            slashingQueue.push(SlashingEvent(operator, amount)); //, notifier, rewardMultiplier));
        }

        if (notifier != address(0)) {
            uint256 reward = (_operators.length * notificationReward).percent(
                rewardMultiplier
            );
            reward = Math.min(reward, notifiersTreasury);
            emit NotifierRewarded(notifier, reward);
            if (reward != 0) {
                notifiersTreasury -= reward;
                token.safeTransfer(notifier, reward);
            }
        }
    }

    /// @notice Processes one specified slashing event.
    ///         Executes `involuntaryAllocationDecrease` function on each
    ///         affected application.
    function processSlashing(SlashingEvent storage slashing)
        internal
        returns (uint256 tAmountToBurn)
    {
        OperatorInfo storage operator = operators[slashing.operator];
        uint256 tAmountToSlash = slashing.amount;

        // slash T
        if (operator.tStake > 0) {
            if (tAmountToSlash <= operator.tStake) {
                tAmountToBurn = tAmountToSlash;
                operator.tStake -= tAmountToSlash;
                tAmountToSlash = 0;
            } else {
                tAmountToBurn = operator.tStake;
                tAmountToSlash -= operator.tStake;
                operator.tStake = 0;
            }
        }

        // slash KEEP
        if (tAmountToSlash > 0 && operator.keepStake > 0) {
            // TODO sync keep stake or skip or ???

            uint256 tKeepEquivalentAmountToBurn;
            if (tAmountToSlash <= operator.keepStake) {
                tKeepEquivalentAmountToBurn = tAmountToSlash;
                operator.keepStake -= tAmountToSlash;
                tAmountToSlash = 0;
            } else {
                tKeepEquivalentAmountToBurn = operator.keepStake;
                tAmountToSlash -= operator.keepStake;
                operator.keepStake = 0;
            }

            (uint256 keepAmountToBurn, uint256 tRemainder) = keepVendingMachine
                .conversionFromT(tKeepEquivalentAmountToBurn);
            tAmountToSlash += tRemainder; // TODO ????
            address[] memory operatorWrapper = new address[](1);
            operatorWrapper[0] = slashing.operator;
            keepStakingContract.seize(
                keepAmountToBurn,
                100,
                msg.sender,
                operatorWrapper
            );
        }

        // slash NU
        if (tAmountToSlash > 0 && operator.nuStake > 0) {
            uint256 tNuEquivalentAmountToBurn;
            if (tAmountToSlash <= operator.nuStake) {
                tNuEquivalentAmountToBurn = tAmountToSlash;
                operator.nuStake -= tAmountToSlash;
                tAmountToSlash = 0;
            } else {
                tNuEquivalentAmountToBurn = operator.nuStake;
                tAmountToSlash -= operator.nuStake;
                operator.nuStake = 0;
            }

            (uint256 nuAmountToBurn, ) = nucypherVendingMachine.conversionFromT(
                tNuEquivalentAmountToBurn
            );

            uint256 nuProcessorReward = nuAmountToBurn.percent(SLASHING_REWARD_PERCENT);
            nucypherStakingContract.slashStaker(
                operator.owner,
                nuAmountToBurn,
                msg.sender,
                nuProcessorReward
            );
        }

        emit TokensSeized(slashing.operator, slashing.amount - tAmountToSlash);
        authorizationDecrease(slashing.operator, operator);
    }

    /// @notice Synchronize authorizations (if needed) after slashing stake
    function authorizationDecrease(
        address operatorAddress,
        OperatorInfo storage operator
    ) internal {
        uint256 totalStake = operator.tStake +
            operator.nuStake +
            operator.keepStake;
        for (uint256 i = 0; i < operator.authorizedApplications.length; i++) {
            address application = operator.authorizedApplications[i];
            uint256 authorized = operator
                .authorizations[application]
                .authorized;
            if (authorized > totalStake) {
                IApplication(application).involuntaryAuthorizationDecrease(
                    operatorAddress,
                    authorized - totalStake
                ); // TODO cut gas usage
                operator.authorizations[application].authorized = totalStake;
            }
        }
    }
}
