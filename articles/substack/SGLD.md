# Hands-on Stochastic Gradient Langevin Dynamics

### Geometric Deep Learning / Training

[![Patrick R. Nicolas's avatar](https://substackcdn.com/image/fetch/$s_!e6ky!,w_36,h_36,c_fill,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F8dfbe26f-325b-4568-83c9-6614efc415e5_490x490.png)](https://substack.com/@patricknicolas)

[Patrick R. Nicolas](https://substack.com/@patricknicolas)

May 12, 2026

∙ Paid

39

9

Share

Although a powerful and ubiquitous optimization method, the Stochastic Gradient Descent has fundamental structural limitations that make it unsuitable for some types of complex landscapes and Bayesian inference.

The** Stochastic Gradient Langevin Dynamics **(**SGLD**) fills the gap between optimization and random (Monte Carlo) sampling.

Thanks for reading **Hands-on Geometric Deep Learning**! Subscribe for free to receive new posts and support my work.

Subscribe

[![](https://substackcdn.com/image/fetch/$s_!2jSr!,w_1456,c_limit,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F51407a42-1560-40dd-8ec7-b8b517026fe6_2184x1920.heic)](https://substackcdn.com/image/fetch/$s_!2jSr!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F51407a42-1560-40dd-8ec7-b8b517026fe6_2184x1920.heic)

_Geometric Deep Learning, World Models use complex math to overcome limitations of traditional deep learning. We make that math practical through hands-on tutorials._

---

1. **[Why this Matters](https://patricknicolas.substack.com/i/195588353/why-this-matters)**
2. **[Key Takeaways](https://patricknicolas.substack.com/i/195588353/key-takeaways)**
3. **[SGDL Basics](https://patricknicolas.substack.com/i/195588353/sgld-basics)**

   _🏛️ [Gradient Descent Family](https://patricknicolas.substack.com/i/195588353/gradient-descent-family)_
   - [Gradient Descent (GD)](https://patricknicolas.substack.com/i/195588353/gradient-descent-gd)
   - [Stochastic Gradient Descent](https://patricknicolas.substack.com/i/195588353/stochastic-gradient-descent-sgd)
   - [Nesterov Accelerated Gradient (NAG)](https://patricknicolas.substack.com/i/195588353/nesterov-accelerated-gradient-nag)
   - [Adaptive Moment Estimation (ADAM)](https://patricknicolas.substack.com/i/195588353/adaptive-moment-estimation-adam)
   - [Adam with Weight Decay (ADAMW)](https://patricknicolas.substack.com/i/195588353/adam-with-weight-decay-adamw)

   _🏛️ [Stochastic Gradient Langevin Dynamics](https://patricknicolas.substack.com/i/195588353/stochastic-gradient-langevin-dynamics-sgld)_
   - [Langevin Dynamics](https://patricknicolas.substack.com/i/195588353/langevin-dynamics)
   - [Quadratic Loss Function](https://patricknicolas.substack.com/i/195588353/quadratic-loss-function)

4. **[SGLD Deep Dive](https://patricknicolas.substack.com/i/195588353/sgld-deep-dive)**

   _🏛️ [Multimodal Benchmark Functions](https://patricknicolas.substack.com/i/195588353/multimodal-benchmark-functions)_
   - [Ackley’s Benchmark](https://patricknicolas.substack.com/i/195588353/ackleys-benchmark)
   - [Rosenbrock’s Benchmark](https://patricknicolas.substack.com/i/195588353/rosenbrocks-benchmark)

   **\*⚙️ **[Python Environment](https://patricknicolas.substack.com/i/195588353/python-environment)
   **⚙️** [Setup](https://patricknicolas.substack.com/i/195588353/setup)\*

   **\*⚙️ **[Validation](https://patricknicolas.substack.com/i/195588353/validation)\*

   **\*⚙️ **[Evaluation](https://patricknicolas.substack.com/i/195588353/evaluation)\*
   - [Impact of Learning Rate](https://patricknicolas.substack.com/i/195588353/impact-of-learning-rate)
   - [Optimizers Evaluation](https://patricknicolas.substack.com/i/195588353/optimizers-evaluation)

5. **[References](https://patricknicolas.substack.com/i/204561486/hands-on-stochastic-gradient-langevin-dynamics)**
6. **[Q & A](https://patricknicolas.substack.com/i/195588353/q-and-a)**
7. **[Appendix](https://patricknicolas.substack.com/i/195588353/appendix)**
8. **[Paper Review](https://patricknicolas.substack.com/i/195588353/paper-review)**

[![](https://substackcdn.com/image/fetch/$s_!IjF-!,w_1456,c_limit,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F0b7dd490-6c90-4a0e-8d1f-1a17f76ca384_438x104.png)](https://substackcdn.com/image/fetch/$s_!IjF-!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F0b7dd490-6c90-4a0e-8d1f-1a17f76ca384_438x104.png)

---

**👉 Patrick Nicolas** is a 30-year software engineering veteran and consultant specializing in Geometric Deep Learning and World Models, author of _Scala for Machine Learning_, and writer of _Geometric Learning in Python_.

# Why this Matters

**Purpose:** Scientists have been trying to combine function optimization and random sampling to improve reliability of Bayesian inference and the minimization of the loss function in training of large models. **Stochastic Gradient Langevin Dynamics (SGLD)** mitigates the risk of converging to local minima by injecting Gaussian noise proportional to the square root of the learning rate, thereby facilitating global exploration of the loss landscape.

**Audience**: Data scientists and researchers looking to expand their understanding and evaluate alternative for Bayesian inference or training deep learning models.

**Value: **Learn the behavior of the Stochastic Gradient Langevin Dynamics as compared to Stochastic Gradient Descent and Adam algorithm using landscape loss function (e.g. Ackley).

# Key Takeaways

- By injecting “controlled jitter” (Gaussian noise) into the update step, **SGLD** successfully hops out of the shallow local minima that often trap standard gradient-based methods.
- Using mathematical “playgrounds” like the **Ackley or Rosenbrock functions** allows us to isolate and visualize how an optimizer handles complex curvatures before testing on actual data.
- PyTorch’s modular design makes SGLD easy to build; you just inherit the **Optimizer** class and plug your custom logic into the s**tep() ** method.
- Interestingly, SGLD acts as a bridge between worlds: it mirrors the broad exploration of **SGD** when the learning rate is high and shifts toward the precision of **ADAM** as the rate cools down.

# SGLD Basics

This section covers the essential **Basics**, while the **Deep Dive** section delivers advanced concepts, real-world applicability, dedicated Q&A and review.

---

The best strategy to evaluate **SGLD** is to compare it with optimization methods we are all familiar with - Stochastic Gradient Descent and Adam.

## _🏛️ Gradient Descent Family_

### Gradient Descent (GD)

The Gradient Descent is the simplest form of optimization and a direct application of calculus. This is an iterative optimization algorithm used to minimize loss functions in machine learning.

Give a learning rate **_α_**, a loss function **_L_**, feature values vector*** x*** and label*** y ***

wt=wt−1−α∇wL(wt−1,x,y)

### Stochastic Gradient Descent (SGD)

The vanilla Gradient Descent is notorious for slow convergence toward global minimum as it requires to process the entire datasets.

The stochastic version enables faster, highly efficient, and scalable learning for large datasets with two improvements has been made to the original Gradient Descent \[ref _1_\]:

- **Selecting** the random training pair features-label **_{xi, yi}_**
- **Organizing** these random training samples into mini-batch of size **_m_**

wt=wt−1−αm∑i=0m∇wL(wt(i),x(i),y(i))

SGD is noisy but converges faster than the original Gradient Descent.

### Nesterov Accelerated Gradient (NAG)

Given the momentum **_v_**, the momentum coefficient ***β, ***the learning rate*** α ***and the mini-batch of size **_m_**

vt=wt−1−wt vt=βvt−1−αm∑i=0n\[∇wL(βvt−1−wt−1(i),x(i),y(i))\]

Nesterov acceleration changes the convergence rate of gradient descent on convex functions.

- **Gradient Descent:** Converges at a rate of **_O(1/t)_**
- **Nesterov Momentum:** Converges at a rate of*** O(1/t\*\*2)***

### Adaptive Moment Estimation (ADAM)

Adam computationally efficient optimization algorithm for training deep learning model**s**, addressing the short comings of SGD by combining the benefits of AdaGrad and RMSProp \[ref **_2_**\]

It updates the learning rates for each parameter as described by the formulas below, using two momenta

- **First moment** - similar to the mean - **\*m (**1)\*
- **Second moment** or adjusted variance**\* v **(2)\*

mt=β1tmt−1+(1−β1t)∇wL(wt−1,x,y) (1)vt=β2tvt−1+(1−β2t)\[∇wL(wt−1,x,y)\]2 (2)m~t=mt1−β1t v~t=vt1−β2t (3) wt=wt−1−αm~tv~t (4)

The two momentum coefficients are normalized by their respective momentum scale factors (3).

### Adam with Weight Decay (AdamW)

The update formula (4) can be improved by applying a linear decay function to the model parameters **_w_** with a factor **_λ_**

wt=wt−1−α\[m~tv~t+λwt−1\] (5)

## _🏛️ Stochastic Gradient Langevin Dynamics (SGLD)_

SGLD is derived from the Langevin mathematical formulation of the dynamics of molecular systems. From a Bayesian perspective, the Langevin method samples from the posterior distribution **_p(w |x)._**

### Langevin dynamics

Langevin dynamics explores the landscape, escapes shallow valleys, and converges to a** Gibbs distribution** that places more weight on low-energy regions. In other words, it bridges optimization and inference: it can act like a noisy optimizer \[ref **_3_**, **_4_**\]

[![Langevin dynamics explores the landscape, escapes shallow valleys, and converges to a Gibbs distribution that places more weight on low-energy regions. In other words, it bridges optimization and inference: it can act like a noisy optimizer](https://substackcdn.com/image/fetch/$s_!ckYN!,w_1456,c_limit,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F6f689def-fce4-4039-98cb-11bb6fe9ce04_1042x786.heic "Langevin dynamics explores the landscape, escapes shallow valleys, and converges to a Gibbs distribution that places more weight on low-energy regions. In other words, it bridges optimization and inference: it can act like a noisy optimizer")](https://substackcdn.com/image/fetch/$s_!ckYN!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F6f689def-fce4-4039-98cb-11bb6fe9ce04_1042x786.heic)

**_Fig. 1 Illustration of the trajectory of a Stochastic Gradient Langevin dynamics on a Ackley loss function/landscape_**

**Stochastic gradient Langevin dynamics** (SGLD) combines the two ideas, mixing minibatch gradients with structured (Gaussian) noise. SGLD uses mini-batching to create random gradient estimate similarly to SGD. Therefore, SGDL has two components:

- **Deterministic drift** (the gradient of the loss)
- **Stochastic diffusion** (the injected Gaussian noise)

This makes it scalable to large datasets while retaining the ability to balance exploitation with exploration, a concept borrowed from reinforcement learning.

The update formula is

wt=wt−1−α∇wL(wt−1,x,y)+2α N(0,Id)|t (6)

---

- 📌 Beside been used as a stochastic optimization method, SGLD is a sampling method related to Markov Chain Monte Carlo and Bayesian learning \[ref **5**\]\*

---

### Quadratic Loss Function

The first test is to compare various optimizers with a convex function (single global minimum). The simplest form of convex function is the ubiquitous quadratic symmetric function. For a two parameters **_w1_**, **_w2_** (vector **_w_** of **_n_** parameters) and a scale coefficient*** λ.***

f(w1,w2)=λ(w12+w22) f(w)=λ∑i=0nwi2

[![The simplest form of convex function is the ubiquitous quadratic symmetric function.](https://substackcdn.com/image/fetch/$s_!S_T3!,w_1456,c_limit,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F0ee54088-9378-406a-b781-064d46abe3e5_860x672.heic "The simplest form of convex function is the ubiquitous quadratic symmetric function.")](https://substackcdn.com/image/fetch/$s_!S_T3!,f_auto,q_auto:good,fl_progressive:steep/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2F0ee54088-9378-406a-b781-064d46abe3e5_860x672.heic)

**_Fig. 2 Illustration of the symmetric quadratic loss function_**

_🔓 The rest of this deep dive is exclusive to paid subscribers. By upgrading, you unlock this full article along with a comprehensive archive of engineering articles, paper review, concept breakdowns, code walkthrough, GitHub repository and Q&A_
