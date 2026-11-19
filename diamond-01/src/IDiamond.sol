// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for the LumerinDiamond on Base, covering only the
/// selectors used by the PoC tests. Function signatures mirror the deployed
/// facet interfaces (Morpheus-Lumerin-Node smart-contracts, release v7.20.0),
/// whose selector sets were verified to match the on-chain loupe output.
interface IDiamond {
    struct Bid {
        address provider;
        bytes32 modelId;
        uint256 pricePerSecond;
        uint256 nonce;
        uint128 createdAt;
        uint128 deletedAt;
    }

    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }

    struct Pool {
        uint256 initialReward;
        uint256 rewardDecrease;
        uint128 payoutStart;
        uint128 decreaseInterval;
    }

    enum FacetAction {
        Add,
        Replace,
        Remove
    }

    struct Facet {
        address facetAddress;
        FacetAction action;
        bytes4[] functionSelectors;
    }

    // --- Diamond (OwnableDiamond) ---
    function owner() external view returns (address);
    function diamondCut(Facet[] calldata facets_, address init_, bytes calldata initData_) external;

    // --- ProviderRegistry ---
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function providerDeregister(address provider_) external;
    function getProviderMinimumStake() external view returns (uint256);
    function getIsProviderActive(address provider_) external view returns (bool);

    // --- ModelRegistry ---
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
    function getModelMinimumStake() external view returns (uint256);
    function getIsModelActive(bytes32 modelId_) external view returns (bool);

    // --- Marketplace ---
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32 bidId);
    function getBid(bytes32 bidId_) external view returns (Bid memory);
    function isBidActive(bytes32 bidId_) external view returns (bool);
    function getBidId(address provider_, bytes32 modelId_, uint256 nonce_) external pure returns (bytes32);
    function getBidFee() external view returns (uint256);
    function getMinMaxBidPricePerSecond() external view returns (uint256, uint256);
    function getToken() external view returns (address);

    // --- SessionRouter ---
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getUserStakesOnHold(address user_, uint8 iterations_)
        external
        view
        returns (uint256 available_, uint256 hold_);
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getSessionId(address user_, address provider_, bytes32 bidId_, uint256 sessionNonce_)
        external
        pure
        returns (bytes32);
    function getIsProviderApprovalUsed(bytes calldata approval_) external view returns (bool);
    function getProvidersTotalClaimed() external view returns (uint256);
    function getFundingAccount() external view returns (address);
    function getComputeBalance(uint128 timestamp_) external view returns (uint256);

    // --- facet initializers (registered selectors, one-shot) ---
    function __SessionRouter_init(address fundingAccount_, uint128 maxSessionDuration_, Pool[] calldata pools_)
        external;
    function __Marketplace_init(address token_, uint256 bidMinPricePerSecond_, uint256 bidMaxPricePerSecond_)
        external;

    // --- errors used by expectRevert ---
    error SessionDuplicateApproval();
    error SessionApprovedForAnotherUser();
    error OwnableUnauthorizedAccount(address account);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}
